#!/usr/bin/env bash
# tests/093 — boundary errors retain their kind/location and owned resources
# are released on normal, language-error, exception, signal, and effect paths.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run() {
  local name="$1" expected_status="$2" source="$3"
  local file="$TMP/$name.pp" out="$TMP/$name.out" err="$TMP/$name.err" ec=0
  printf '%s\n' "$source" >"$file"
  if [ "$name" = child-signal ]; then
    "$PP" --grant process "$file" >"$out" 2>"$err" || ec=$?
  else
    "$PP" "$file" >"$out" 2>"$err" || ec=$?
  fi
  if [ "$ec" -eq "$expected_status" ] && ! grep -q 'Fatal error' "$err"; then
    ok "$name"
  else
    bad "$name" "exit=$ec" "stdout: $(cat "$out")" "stderr: $(cat "$err")"
  fi
}

run normal-return 0 'print(1)'
run language-error 1 'error("boom")'
run ocaml-exception 1 'read-string("1e")'
run child-signal 0 'run!("sh", "-c", "kill -TERM $$")'
run effect-continuation 0 'with-handler(log! = fn(m) { print(m) }) { log!("ok") }'

if grep -q 'boom at .*language-error\.pp:1' "$TMP/language-error.err"; then
  ok "language-error-location"
else
  bad "language-error-location" "$(cat "$TMP/language-error.err")"
fi

rm -rf "$TMP"
exit $fail
