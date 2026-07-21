#!/usr/bin/env bash
# Every retained top-level example demonstrates current language and executes.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

for file in examples/*.pp; do
  name=$(basename "$file" .pp)
  actual="$TMP/$name.out"
  expected="$file.expected"
  if ! "$PP" "$file" >"$actual" 2>&1; then
    bad "example-$name" "$(cat "$actual")"
  elif [ ! -f "$expected" ]; then
    bad "example-$name" "missing $expected"
  elif diff -u "$expected" "$actual" >"$TMP/$name.diff"; then
    ok "example-$name"
  else
    bad "example-$name" "$(cat "$TMP/$name.diff")"
  fi
done

exit $fail
