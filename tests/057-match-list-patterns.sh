#!/usr/bin/env bash
# tests/057 — Differential test for match list patterns (Phase 3.1).
# `match` patterns are not yet representable in the sexpr surface, so this
# test is a shell script (not a .pp file) to avoid breaking the M7 S1/S2
# round-trip sweeps.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

run_both() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP" "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" != "$expected" ]; then
    bad "$name-tw" "expected: $(printf '%q' "$expected")" "got:      $(printf '%q' "$got_tw")"
  elif [ "$got_bc" != "$expected" ]; then
    bad "$name-bc" "expected: $(printf '%q' "$expected")" "got:      $(printf '%q' "$got_bc")"
  else
    ok "$name"
  fi
}

cat > "$TMP/basic.pp" <<'EOF'
let x = [1, 2, 3]
match x {
  [a, b, c] => print(a + b + c)
  _ => print(0)
}
EOF
run_both "basic-list-pattern" "$TMP/basic.pp" "6"

cat > "$TMP/nested.pp" <<'EOF'
let y = [[1, 2], [3, 4]]
match y {
  [[a, b], [c, d]] => print(a + b + c + d)
  _ => print(0)
}
EOF
run_both "nested-list-pattern" "$TMP/nested.pp" "10"

cat > "$TMP/literal.pp" <<'EOF'
let z = [10, 20]
match z {
  [1, a] => print(a)
  [10, b] => print(b)
  _ => print(0)
}
EOF
run_both "literal-and-wildcard" "$TMP/literal.pp" "20"

cat > "$TMP/empty.pp" <<'EOF'
let w = []
match w {
  [] => print(:empty)
  _ => print(:nonempty)
}
EOF
run_both "empty-list-pattern" "$TMP/empty.pp" ":empty"

cat > "$TMP/order.pp" <<'EOF'
let fail = [1]
match fail {
  [a, b] => print(:two)
  [a] => print(:one)
  _ => print(:other)
}
EOF
run_both "pattern-order-fallback" "$TMP/order.pp" ":one"

cat > "$TMP/spread.pp" <<'EOF'
let x = [1, 2, 3, 4]
match x {
  [a, ...rest] => print(a + car(rest))
  _ => print(0)
}
EOF
run_both "list-pattern-spread" "$TMP/spread.pp" "3"

cat > "$TMP/spread-wildcard.pp" <<'EOF'
let y = [10, 20, 30, 40]
match y {
  [a, b, ..._] => print(a + b)
  _ => print(0)
}
EOF
run_both "list-pattern-spread-wildcard" "$TMP/spread-wildcard.pp" "30"

rm -rf "$TMP"
exit $fail
