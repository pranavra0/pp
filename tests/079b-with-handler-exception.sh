#!/usr/bin/env bash
# tests/079b — D24: exception-safe dynamic extent for with-handler/with-config.
# Both backends must restore the outer handler/config after an exception
# inside the body — the installed handler or config must not leak past the
# error. Tested via piped REPL input so that errors don't abort the process.
#
# Pins: D24 (exception-safe dynamic extent).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run_repl_both() {
  local name="$1" input="$2" expected="$3"
  local got_tw got_bc
  got_tw=$(printf '%s' "$input" | "$PP"            2>&1)
  got_bc=$(printf '%s' "$input" | "$PP" --bytecode 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "tw:       $(printf '%q' "$got_tw")" "bc:       $(printf '%q' "$got_bc")"
  fi
}

# (a) with-handler: inner handler installed, exception raised, outer handler used after
run_repl_both "handler-exception-safe" \
'with-handler(log = fn(m) { print("INNER:", m) }) {
  error("boom")
}
perform log("after-error")
' \
'Error: boom at <repl>:1
[info] after-error
nil'

# (b) with-config: inner config installed, exception raised, outer config used after
run_repl_both "config-exception-safe" \
'with-config({:k -> "inner"}) {
  error("boom")
}
print("config k after:", config(:k, "outer-default"))
' \
'Error: boom at <repl>:1
"config k after:""outer-default"
nil'

rm -rf "$TMP"
exit $fail
