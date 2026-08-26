#!/usr/bin/env bash
# Tail calls through dynamic scopes stay constant-stack and linear-time.
# pins: LAW-10
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run_limited() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 30 "$PP" "$1"
  else
    perl -e 'alarm 30; exec @ARGV' "$PP" "$1"
  fi
}

prepare_case() {  # NAME DEFINITION — write the program; print nothing
  local name="$1" definition="$2"
  {
    printf '%s\n' "$definition"
    printf '%s\n' 'print(loop(50000))'
  } >"$TMP/$name.pp"
}

# The three cases are independent processes, so they run concurrently; each
# lane records its own exit code, and verdicts replay in declaration order.
run_lane() {  # NAME — run the prepared case, recording its exit code
  local name="$1"
  run_limited "$TMP/$name.pp" >"$TMP/$name.out" 2>&1
  printf '%d' "$?" > "$TMP/$name.rc"
}

declare -A CASE_DEFS=(
  [config-tail]='def loop(n) { if n <= 0 { 0 } else { with-config({:k -> 1}) { loop(n - 1) } } }'
  [handler-tail]='def loop(n) { if n <= 0 { 0 } else { with-handler(log = fn(x) { x }) { loop(n - 1) } } }'
  [caps-tail]='def loop(n) { if n <= 0 { 0 } else { with-caps(cap-none()) { loop(n - 1) } } }'
)
for name in config-tail handler-tail caps-tail; do prepare_case "$name" "${CASE_DEFS[$name]}"; done
for name in config-tail handler-tail caps-tail; do run_lane "$name" & done
wait
for name in config-tail handler-tail caps-tail; do
  rc=$(cat "$TMP/$name.rc")
  if [ "$rc" -eq 0 ] && grep -q '^0$' "$TMP/$name.out"; then
    ok "$name"
  else
    bad "$name" "expected a bounded scoped tail call" "$(cat "$TMP/$name.out")"
  fi
done

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== TAIL SCOPES TEST PASSED ==="; fi
exit "$fail"
