#!/usr/bin/env bash
# tests/057 — Differential test for match list patterns. Kept as a shell
# script (not a .pp file) for its expected-output oracle; the sexpr surface
# also represents match, and tests/084 covers its round-trip.
# Also pins two match soundness fixes:
#   - matching a list/tagged pattern against a non-pair scalar falls through
#     (the compiler's `car`/`cdr` are now cons-guarded, matching the
#     tree-walker) instead of crashing the VM;
#   - a match nested in another match's scrutinee no longer collides on the
#     compiler's scrutinee temp (unique per instance now).
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

# A list/tagged pattern matched against a NON-PAIR scalar must fall through
# (not crash the VM on car(scalar)). Covers every scalar shape.
cat > "$TMP/scalar.pp" <<'EOF'
def f(x) {
  match x {
    [:ok, v] => v
    [a, b] => a
    _ => "fell-through"
  }
}
print(f(42))
print(f("s"))
print(f(:kw))
print(f(nil))
EOF
run_both "list-pattern-vs-scalar-falls-through" "$TMP/scalar.pp" \
  $'"fell-through"\n"fell-through"\n"fell-through"\n"fell-through"'

# A match nested in another match's scrutinee (shared VM frame): the inner
# result must reach the outer scrutinee intact on both backends.
cat > "$TMP/nested-scrut.pp" <<'EOF'
def inner(k) { match k { 3 => 99; _ => 8 } }
def f(s) {
  match 0 + inner(s) {
    2 => 42
    8 => 1920
    _ => 76
  }
}
print(f(-28))
print(f(3))
EOF
# f(-28): inner=8 → scrut 8 → 1920.  f(3): inner=99 → scrut 99 → _ → 76.
run_both "match-nested-in-scrutinee" "$TMP/nested-scrut.pp" $'1920\n76'

# ... and the same with guards on both the inner and outer match.
cat > "$TMP/nested-guard.pp" <<'EOF'
def inner(k) { match k { n if n > 4 => n; _ => 8 } }
def f(s) {
  match 0 + inner(s) {
    2 => 42
    n if n > 1 => 10 + n + 90 * n
    _ => 76
  }
}
print(f(-28))
print(f(7))
EOF
# f(-28): inner=8 → 10+8+720=738.  f(7): inner=7 → 10+7+630=647.
run_both "match-nested-guarded" "$TMP/nested-guard.pp" $'738\n647'

rm -rf "$TMP"
exit $fail
