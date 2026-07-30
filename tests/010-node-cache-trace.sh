#!/usr/bin/env bash
# Regression: node-cache validity is a VERIFYING TRACE, not just the node key
# (SPEC law 21).
#
# Two facts about the persistent node cache (~/.pp/store) motivated this:
#   1. it was tree-walker-only (no store of its own existed), and
#   2. it served STALE results: `node { $file(path) }` returned the old file
#      contents after the file changed, because the node key hashes the path
#      STRING, not what was read.
#
# The fix records each world-read as a (cell-id, observed-hash) pair in the
# node's trace and re-verifies every pair on a cache hit. This is pp's dynamic
# answer to Haskell's static IO type: a "pure-enough"
# heuristic cannot make caching sound in a dynamically-typed language — only
# recording what a run actually observed can.
#
# The store lives at $HOME/.pp/store, so this test runs under an isolated HOME
# and never touches the developer's real store. It exercises only the
# single tree-walking evaluator.
. "$(dirname "$0")/lib.sh"
DATA="$TMP/data.txt"
PROG="$TMP/prog.pp"

# A node that logs "COMPUTE" (an ephemeral effect) then returns the file it
# read. On a MISS the body runs, so stderr shows "COMPUTE"; on a HIT the body
# is skipped and — per SPEC law 17 — "COMPUTE" is NOT replayed. The outer log always
# emits the resulting content, so we can read the served value every run.
cat > "$PROG" <<EOF
log!(force(node {
  log!("COMPUTE")
  \$file("$DATA")
}))
EOF

run() { rm -f "$TMP/out"; "$PP" --grant "fs:$TMP:ro" "$PROG" > "$TMP/out" 2>&1; cat "$TMP/out"; }

# assert_grep NAME PATTERN present|absent
assert() {
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$pat' $mode, got $hit"
    echo "--- output ---"; cat "$TMP/out"; fail=1
  fi
}

rm -rf "$TMP/.pp"

printf 'V1\n' > "$DATA"
run > /dev/null
assert "run1-miss-computes"  "COMPUTE" present   # cold: body runs
assert "run1-value-V1"       "V1"      present

run > /dev/null
assert "run2-hit-no-recompute" "COMPUTE" absent  # unchanged file ⇒ trace verifies ⇒ hit
assert "run2-value-V1"         "V1"      present  # LAW 17: hit does not replay COMPUTE

printf 'V2\n' > "$DATA"
run > /dev/null
assert "run3-stale-recomputes" "COMPUTE" present  # file changed ⇒ trace stale ⇒ miss
assert "run3-value-V2"         "V2"      present   # THE FIX: fresh content, not stale V1
assert "run3-not-stale-V1"     "^\[info\] V1$" absent

# Trace SET (R9): reverting the file hits the ORIGINAL trace, still in the set.
printf 'V1\n' > "$DATA"
run > /dev/null
assert "run4-revert-hit"   "COMPUTE" absent
assert "run4-value-V1"     "V1"      present

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then
  echo "=== NODE-CACHE TRACE TEST PASSED ==="
fi
exit $fail
