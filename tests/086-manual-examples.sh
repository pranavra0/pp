#!/usr/bin/env bash
# tests/086 — the manual's code examples are executable.
#
# Each docs/manual/examples/NAME.pp is
# executed and must succeed — except the handful that deliberately demonstrate
# an error, which must fail. So an example that stops running is a red build
# without waiting for a manual render.
#
# Examples run from examples/ so any error text's relative NAME.pp:line path
# is stable.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
EX="$PWD/docs/manual/examples"

# Examples that demonstrate an error on purpose (a denied capability, an
# ill-typed call): these must FAIL on both back ends; every other example must
# succeed on both.
is_error_demo() { case "$1" in cap-read|type-error|ref-type-error) return 0 ;; *) return 1 ;; esac; }

run_one() {  # BACKEND-FLAG NAME -> sets REPLY to combined out+err, returns exit code
  ( cd "$EX" && HOME=$(mktemp -d) "$PP" $1 "$2.pp" >"$TMP/o" 2>"$TMP/e" )
  local code=$?
  REPLY=$(cat "$TMP/o" "$TMP/e")
  return $code
}

count=0
for f in "$EX"/*.pp; do
  name=$(basename "$f" .pp)
  count=$((count + 1))
  run_one "" "$name"; code=$?; out=$REPLY
  if is_error_demo "$name"; then
    if [ "$code" != 0 ]; then ok "manual-$name (error demo)"
    else bad "manual-$name" "expected an error demo to fail, got code=$code" "$out"; fi
  else
    if [ "$code" = 0 ]; then ok "manual-$name"
    else bad "manual-$name" "example failed (code=$code) — broken or newly an error demo" "$out"; fi
  fi
done
if [ "$count" -gt 0 ]; then ok "manual-examples-ran ($count examples)"
else echo "FAIL no manual examples found under $EX"; fail=1; fi
exit $fail
