#!/usr/bin/env bash
# tests/085 — a failed type-annotation check must not leave the thunk stuck
# `Evaluating`. Typed thunks are memoised by content hash
# (Evaluator.make_thunk_ca_typed), so if check_type raised outside the
# status-reset guard the thunk stayed `Evaluating` and the NEXT force of the
# same content hash misreported "infinite recursion" instead of the real type
# error. The REPL is the reachable trigger: it catches a per-line error and
# keeps the thunk store alive, so entering the same ill-typed form twice forces
# the same memoised thunk twice.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# Two byte-identical ill-typed forms. BOTH lines must report the type
# mismatch; neither may mention "infinite recursion". Checked on both backends.
prog='let (x: int = "oops") { x }
let (x: int = "oops") { x }'

for flags in "" "--bytecode"; do
  name="reforce${flags:+-vm}"
  out=$(printf '%s\n' "$prog" | "$PP" $flags 2>&1)
  mismatches=$(printf '%s\n' "$out" | grep -c 'type mismatch: expected int')
  if printf '%s\n' "$out" | grep -q 'infinite recursion'; then
    bad "$name" "second force misreported a cycle instead of the type error" "$out"
  elif [ "$mismatches" -eq 2 ]; then
    ok "$name"
  else
    bad "$name" "expected two type-mismatch errors, got $mismatches" "$out"
  fi
done

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== TYPED THUNK RE-FORCE TEST PASSED ==="; fi
exit $fail
