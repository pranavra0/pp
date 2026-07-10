#!/usr/bin/env bash
# Regression: node-cache validity is a VERIFYING TRACE, not just the node key.
#
# Two facts about the persistent node cache (~/.pp/store) motivated this:
#   1. it was tree-walker-only (the VM has no store — D7), and
#   2. it served STALE results: `(node (slurp path))` returned the old file
#      contents after the file changed, because the node key hashes the path
#      STRING, not what was read.
#
# The fix records each world-read as a (cell-id, observed-hash) pair in the
# node's trace and re-verifies every pair on a cache hit. This is pp's dynamic
# answer to Haskell's static IO type (SPEC LAW 21, DESIGN Q2/Q8): a "pure-enough"
# heuristic cannot make caching sound in a dynamically-typed language — only
# recording what a run actually observed can.
#
# The store lives at $HOME/.pp/store, so this test runs under an isolated HOME
# and never touches the developer's real store. It exercises only the
# tree-walker (the sole backend wired to the store) and separately pins the
# documented VM behaviour (recomputes every run).
set -uo pipefail
PP=${PP:-bin/pp}
# Resolve PP to an absolute path before we move cwd via HOME-isolated runs.
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"          # isolate ~/.pp/store to the sandbox
DATA="$TMP/data.txt"
PROG="$TMP/prog.pp"
fail=0

# A node that logs "COMPUTE" (an ephemeral effect) then returns the file it
# read. On a MISS the body runs, so stderr shows "COMPUTE"; on a HIT the body
# is skipped and — per LAW 17 — "COMPUTE" is NOT replayed. The outer log always
# emits the resulting content, so we can read the served value every run.
cat > "$PROG" <<EOF
(perform log
  (force (node (do (perform log "COMPUTE") (slurp "$DATA")))))
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
assert "tw-run1-miss-computes"  "COMPUTE" present   # cold: body runs
assert "tw-run1-value-V1"       "V1"      present

run > /dev/null
assert "tw-run2-hit-no-recompute" "COMPUTE" absent  # unchanged file ⇒ trace verifies ⇒ hit
assert "tw-run2-value-V1"         "V1"      present  # LAW 17: hit does not replay COMPUTE

printf 'V2\n' > "$DATA"
run > /dev/null
assert "tw-run3-stale-recomputes" "COMPUTE" present  # file changed ⇒ trace stale ⇒ miss
assert "tw-run3-value-V2"         "V2"      present   # THE FIX: fresh content, not stale V1
assert "tw-run3-not-stale-V1"     "^\[info\] V1$" absent

# Trace SET (R9): reverting the file hits the ORIGINAL trace, still in the set.
printf 'V1\n' > "$DATA"
run > /dev/null
assert "tw-run4-revert-hit"   "COMPUTE" absent
assert "tw-run4-value-V1"     "V1"      present

# The VM is now wired to the same store (D7 closed): a fresh-store run misses and
# computes, an unchanged re-run hits, and editing the file re-computes — the same
# trace-verified caching as the tree-walker.
rm -rf "$TMP/.pp"
printf 'V1\n' > "$DATA"
"$PP" --bytecode --grant "fs:$TMP:ro" "$PROG" > "$TMP/out" 2>&1
assert "vm-run1-miss-computes"    "COMPUTE" present
"$PP" --bytecode --grant "fs:$TMP:ro" "$PROG" > "$TMP/out" 2>&1
assert "vm-run2-hit-no-recompute" "COMPUTE" absent
printf 'V2\n' > "$DATA"
"$PP" --bytecode --grant "fs:$TMP:ro" "$PROG" > "$TMP/out" 2>&1
assert "vm-run3-stale-recomputes" "COMPUTE" present

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then
  echo "=== NODE-CACHE TRACE TEST PASSED ==="
fi
exit $fail
