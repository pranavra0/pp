#!/usr/bin/env bash
# tests/063 — match lowering must be unaffected by user shadowing of the
# primitives it compiles down to (car/cdr/=/nil?/not/error).
#
# The VM compiler lowers `match` to a nested let+if chain built from
# EApply (ESymbol "car"/"cdr"/"="/"nil?"/"not"/"error", ...). Before the fix,
# these were ordinary symbol references, so they compiled to LOAD_GLOBAL
# "car" etc. and resolved to whatever the CURRENT global binding was — if
# user code shadowed one of these names (e.g. `def car(x) { :BROKEN }`), the
# VM's match machinery silently called the user's redefinition instead of
# the true primitive. The tree-walker evaluates `match` structurally via
# Types.match_pattern and is immune to shadowing, so the two backends would
# diverge: a correctness bug in a language whose whole point is backend
# agreement. This test shadows every primitive the lowering depends on and
# pins that both backends still produce the correct, IDENTICAL result.
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
  elif [ "$got_tw" != "$got_bc" ]; then
    bad "$name-parity" "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")"
  else
    ok "$name"
  fi
}

# Baseline: plain, unshadowed match over list and tagged patterns — pins
# correct structural behavior with no shadowing in scope.
cat > "$TMP/baseline.pp" <<'EOF'
let x = [1, 2, 3]
match x {
  [a, b, c] => print(a + b + c)
  _ => print(0)
}
let p = [:point, 3, 4]
match p {
  (:point a b) => print(a * b)
  _ => print(0)
}
match 5 {
  5 => print(:five)
  _ => print(:other)
}
EOF
run_both "baseline-unshadowed" "$TMP/baseline.pp" $'6\n12\n:five'

# Shadowed: user code redefines every primitive the match lowering depends
# on (car, cdr, =, nil?, not, error). Structural match result must be
# unchanged, and the internal match-failure path must still raise the TRUE
# "match failure" error (via the unshadowable alias), not the user's
# redefinition of `error`.
cat > "$TMP/shadow.pp" <<'EOF'
def car(x) { :BROKEN }
def cdr(x) { :BROKEN }
def = (a, b) { false }
def nil?(x) { false }
def not(x) { :not_broken }
def error(x) { :err_broken }

let x = [1, 2, 3]
match x {
  [a, b, c] => print(a + b + c)
  _ => print(0)
}

let p = [:point, 3, 4]
match p {
  (:point a b) => print(a * b)
  _ => print(0)
}

match 5 {
  5 => print(:five)
  _ => print(:other)
}

let one = [1]
match one {
  [a, b] => print(:two)
  [a] => print(:one)
  _ => print(:other)
}
EOF
run_both "shadowed-primitives-structural" "$TMP/shadow.pp" $'6\n12\n:five\n:one'

# Shadowed `error`, and no arm matches: the internal match-failure fallback
# must still raise the true "match failure" error, not silently return the
# user's shadowed `:err_broken`.
cat > "$TMP/shadow-fallthrough.pp" <<'EOF'
def error(x) { :err_broken }
match 99 {
  1 => print(:no)
}
EOF
expected="pp: error: match failure at $TMP/shadow-fallthrough.pp:2"
got_tw=$("$PP" "$TMP/shadow-fallthrough.pp" 2>&1)
got_bc=$("$PP" --bytecode "$TMP/shadow-fallthrough.pp" 2>&1)
if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
  ok "shadowed-error-fallthrough-still-raises"
else
  bad "shadowed-error-fallthrough-still-raises" \
      "expected: $(printf '%q' "$expected")" \
      "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")"
fi

rm -rf "$TMP"
exit $fail
