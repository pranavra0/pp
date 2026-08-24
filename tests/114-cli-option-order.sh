#!/usr/bin/env bash
# CLI options compose independently of their order.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
trap 'rm -rf "$TMP"' EXIT

"$PP" --grant process -e 'print(1)' >"$TMP/out" 2>&1
status=$?
if [ "$status" -eq 0 ] && grep -q '^1$' "$TMP/out"; then
  ok "grant-before-e"
else
  bad "grant-before-e" "exit=$status output=$(cat "$TMP/out")"
fi

exit "$fail"
