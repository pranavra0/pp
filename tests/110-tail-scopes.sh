#!/usr/bin/env bash
# Tail calls through dynamic scopes stay constant-stack and linear-time.
# pins: LAW-10
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run_limited() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 "$PP" "$1"
  else
    perl -e 'alarm 10; exec @ARGV' "$PP" "$1"
  fi
}

run_case() {
  local name="$1" definition="$2"
  {
    printf '%s\n' "$definition"
    printf '%s\n' 'print(loop(100000))'
  } >"$TMP/$name.pp"
  run_limited "$TMP/$name.pp" >"$TMP/$name.out" 2>&1
  if [ "$?" -eq 0 ] && grep -q '^0$' "$TMP/$name.out"; then
    ok "$name"
  else
    bad "$name" "expected a bounded scoped tail call" "$(cat "$TMP/$name.out")"
  fi
}

run_case config-tail \
  'def loop(n) { if n <= 0 { 0 } else { with-config({:k -> 1}) { loop(n - 1) } } }'
run_case handler-tail \
  'def loop(n) { if n <= 0 { 0 } else { with-handler(log = fn(x) { x }) { loop(n - 1) } } }'
run_case caps-tail \
  'def loop(n) { if n <= 0 { 0 } else { with-caps(cap-none()) { loop(n - 1) } } }'

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== TAIL SCOPES TEST PASSED ==="; fi
exit "$fail"
