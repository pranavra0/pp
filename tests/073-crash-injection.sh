#!/usr/bin/env bash
# tests/073 — killing pp mid-write, at every possible point, must never corrupt
# the store or produce a wrong result on restart.
# pins: LAW-21 LAW-28 LAW-30
#
# Every durable repository write funnels through `Store_layout.atomic_replace`.
# Its single crash counter lets this test sweep every write boundary without a
# per-site list.
#
# The oracle: PP_CRASH_AT="<boundary>:<n>" sends the process an uncatchable
# SIGKILL at the n-th atomic_write, at one of four boundaries:
#   before      — nothing written yet
#   mid         — content in the temp file, not yet closed/renamed
#   pre-rename  — temp file complete & closed; canonical path still unchanged
#   post-rename — rename done (durable); process dies before doing more work
#
# The invariant (the store is valid-or-invalidated, never wrong): after a kill
# at ANY boundary, a plain restart must (a) not crash on the partial store, and
# (b) produce the byte-identical result of a clean build. A torn temp file is
# never mistaken for a committed object/trace (rename is atomic; a corrupt
# object → miss → recompute; a corrupt trace line → dropped).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
trap 'rm -rf "$TMP"' EXIT
unset PP_CRASH_AT || true

# A build that writes several store objects+traces: two persistent nodes, the
# second depending on the first. Pure (no capability needed) — enough to drive
# object + trace + version writes through the atomic-replacement choke point.
cat > "$TMP/build.pp" <<EOF
let a = force(node { 6 * 7 })
let b = force(node { a + 100 })
print(a)
print(b)
EOF

# Baseline: clean cold build establishes the correct result O.
rm -rf "$TMP/.pp"
baseline=$("$PP" "$TMP/build.pp" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
  bad "baseline" "clean build failed (rc=$rc):" "$baseline"; echo "$fail"; exit 1
fi
ok "baseline (result established: $(printf '%s' "$baseline" | tr '\n' ' '))"

crashes=0     # how many sweep points actually killed the process
recovered=0   # how many of those recovered to the exact baseline

for boundary in before mid pre-rename post-rename; do
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    # Cold store, then crash mid-build at (boundary, n).
    rm -rf "$TMP/.pp"
    # Command substitution runs the doomed process in a subshell, which keeps
    # bash's "Killed: 9" job-control notice off the test output.
    _=$(PP_CRASH_AT="$boundary:$n" "$PP" "$TMP/build.pp" 2>&1)
    crc=$?
    if [ $crc -ne 137 ]; then
      # No crash at this point (n past the build's write count) — nothing to
      # recover from; skip. (rc 0 = completed normally.)
      continue
    fi
    crashes=$((crashes + 1))

    # Restart on the partial store. Must not error, must match baseline.
    rec=$("$PP" "$TMP/build.pp" 2>&1); rrc=$?
    if [ $rrc -ne 0 ]; then
      bad "recover-$boundary-$n" "restart errored (rc=$rrc) on partial store:" "$rec"
      continue
    fi
    if [ "$rec" != "$baseline" ]; then
      bad "recover-$boundary-$n" \
          "WRONG result after crash+restart:" \
          "got:      $(printf '%s' "$rec" | tr '\n' ' ')" \
          "expected: $(printf '%s' "$baseline" | tr '\n' ' ')"
      continue
    fi
    # A second (now-warm) run must also match — exercises serving the
    # recovered/re-committed store rather than a fresh recompute.
    warm=$("$PP" "$TMP/build.pp" 2>&1)
    if [ "$warm" != "$baseline" ]; then
      bad "recover-$boundary-$n-warm" \
          "warm run diverged from baseline:" \
          "got: $(printf '%s' "$warm" | tr '\n' ' ')"
      continue
    fi
    recovered=$((recovered + 1))
  done
done

# The sweep must have actually killed the process at real boundaries — a run
# that crashed nowhere would pass vacuously.
if [ "$crashes" -ge 6 ]; then
  ok "swept $crashes crash points across 4 boundaries"
else
  bad "crash-coverage" "only $crashes crashes observed (expected >= 6); oracle wired?"
fi
if [ "$crashes" -eq "$recovered" ]; then
  ok "every one of $recovered crash points recovered to the baseline result"
else
  bad "recovery" "$recovered/$crashes crash points recovered cleanly"
fi

if [ $fail -eq 0 ]; then echo "=== CRASH-INJECTION (A″4) TEST PASSED ==="; fi
exit $fail
