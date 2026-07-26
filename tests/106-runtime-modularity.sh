#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib.sh"

"$PP" tests/106-runtime-modularity.pp > "$TMP/out" 2>&1
code=$?
if [ "$code" -eq 0 ] && grep -q "library-event" "$TMP/out"; then
  ok "pp-runtime-manifest-and-reporter"
else
  bad "pp-runtime-manifest-and-reporter" "exit=$code" "$(cat "$TMP/out")"
fi

"$PP" --schedule race:2 tests/106-runtime-modularity.pp > "$TMP/override" 2>&1
code=$?
if [ "$code" -eq 0 ] && ! grep -q "runtime-schedule" "$TMP/override" && grep -q "library-event" "$TMP/override"; then
  ok "cli-schedule-overrides-manifest"
else
  bad "cli-schedule-overrides-manifest" "exit=$code" "$(cat "$TMP/override")"
fi
exit "$fail"
