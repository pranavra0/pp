#!/usr/bin/env bash
# pins: LAW-36
# Signed numeric literals agree across both readers without stealing the
# subtraction operator or hyphenated identifiers.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat >"$TMP/numbers.pp" <<'EOF'
def negative-value() { -5 }
print(negative-value())
print(-0.5)
print(7 - 12)
print(number->string(-13))
EOF

cat >"$TMP/numbers.ppl" <<'EOF'
(print -5)
(print -0.5)
(print (- 7 12))
(print (number->string -13))
EOF

"$PP" "$TMP/numbers.pp" >"$TMP/braces.out" 2>&1
"$PP" "$TMP/numbers.ppl" >"$TMP/sexpr.out" 2>&1
printf '%s\n' -5 -0.5 -5 '"-13"' >"$TMP/expected"

if diff -u "$TMP/expected" "$TMP/braces.out" >"$TMP/braces.diff"; then
  ok "negative-literals-braces"
else bad "negative-literals-braces" "$(cat "$TMP/braces.diff")"; fi

if diff -u "$TMP/expected" "$TMP/sexpr.out" >"$TMP/sexpr.diff"; then
  ok "negative-literals-sexpr"
else bad "negative-literals-sexpr" "$(cat "$TMP/sexpr.diff")"; fi

"$PP" fmt --to-sexpr "$TMP/numbers.pp" >"$TMP/formatted.ppl"
"$PP" "$TMP/formatted.ppl" >"$TMP/formatted.out" 2>&1
if diff -u "$TMP/expected" "$TMP/formatted.out" >"$TMP/formatted.diff"; then
  ok "negative-literals-format-roundtrip"
else bad "negative-literals-format-roundtrip" "$(cat "$TMP/formatted.diff")"; fi

if [ "$fail" -eq 0 ]; then echo "=== NEGATIVE LITERALS TEST PASSED ==="; fi
exit "$fail"
