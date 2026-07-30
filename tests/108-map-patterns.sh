#!/usr/bin/env bash
# tests/108 — exact, ignored, and bound map patterns, including closed keys.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/map.pp" <<'EOF'
let x = {"a" -> 1, "b" -> 2}
match x {
  {"a" -> a} => print(:wrong-exact, a)
  {"a" -> a, ..._} => print(:ignore, a)
}
match x {
  {"a" -> a, ...rest} => print(:bind, a, rest)
}
let keyed = {vector(1, list(2, 3)) -> 9}
match keyed {
  {vector(1, list(2, 3)) -> value} => print(:closed-key, value)
  _ => print(:wrong-key)
}
EOF
expected=$':ignore1\n:bind1{"b" 2}\n:closed-key9'
got=$($PP "$TMP/map.pp" 2>&1)
if [ "$got" = "$expected" ]; then ok "map-pattern-modes-and-keys"; else bad "map-pattern-modes-and-keys" "expected: $expected" "got: $got"; fi

if $PP fmt --to-sexpr "$TMP/map.pp" > "$TMP/map.ppl" 2>"$TMP/sexpr.err" \
   && got=$($PP "$TMP/map.ppl" 2>&1) \
   && [ "$got" = "$expected" ]; then
  ok "map-pattern-sexpr-execution"
else
  bad "map-pattern-sexpr-execution" "$(cat "$TMP/sexpr.err" 2>/dev/null)" "got: $got"
fi

if $PP fmt --to-braces "$TMP/map.ppl" > "$TMP/map2.pp" 2>"$TMP/braces.err" \
   && $PP --compare-hash "$TMP/map.pp" "$TMP/map2.pp" >/dev/null 2>&1; then
  ok "map-pattern-format-hash"
else
  bad "map-pattern-format-hash" "$(cat "$TMP/braces.err" 2>/dev/null)"
fi

exit "$fail"
