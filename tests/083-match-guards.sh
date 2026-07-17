#!/usr/bin/env bash
# tests/083 — C3: match guards. `pat if cond => expr` — an arm fires only when
# its pattern matches AND the guard (evaluated under the pattern's bindings) is
# truthy; a falsy guard falls through to the next arm. A guardless arm hashes
# a quasiquote template and a fmt round-trip.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_ok() {
  local name="$1" file="$2" expected="$3"
  local got
  got=$("$PP" "$file" 2>&1)
  if [ "$got" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "got: $(printf '%q' "$got")"
  fi
}

# (a) guard on a variable pattern; first matching+passing arm wins.
cat > "$TMP/classify.pp" <<'EOF'
def classify(n) {
  match n {
    x if x < 0 => "neg"
    0 => "zero"
    x if x > 100 => "big"
    _ => "small"
  }
}
print(classify(-5))
print(classify(0))
print(classify(500))
print(classify(7))
EOF
run_ok "guard-variable-pattern" "$TMP/classify.pp" $'"neg"\n"zero"\n"big"\n"small"'

# (b) guard references a variable BOUND by the same arm's pattern.
cat > "$TMP/describe.pp" <<'EOF'
def describe(r) {
  match r {
    [:ok, v] if v > 10 => "big ok"
    [:ok, v] => "small ok"
    [:err, e] => e
  }
}
print(describe([:ok, 50]))
print(describe([:ok, 3]))
print(describe([:err, "boom"]))
EOF
run_ok "guard-uses-pattern-binding" "$TMP/describe.pp" $'"big ok"\n"small ok"\n"boom"'

# (c) a falsy guard falls through even when the pattern matched — proving the
#     fall-through reaches later arms, not "match failure".
cat > "$TMP/fallthrough.pp" <<'EOF'
def f(n) {
  match n {
    x if false => "never"
    x if x = 3 => "three"
    _ => "other"
  }
}
print(f(3))
print(f(4))
EOF
run_ok "falsy-guard-falls-through" "$TMP/fallthrough.pp" $'"three"\n"other"'

# (d) several consecutive guarded arms (the evaluator fall-through must stay
#     linear and correct across a chain of guards).
cat > "$TMP/chain.pp" <<'EOF'
def grade(n) {
  match n {
    x if x >= 90 => "A"
    x if x >= 80 => "B"
    x if x >= 70 => "C"
    _ => "F"
  }
}
print(grade(95))
print(grade(85))
print(grade(72))
print(grade(50))
EOF
run_ok "guard-chain" "$TMP/chain.pp" $'"A"\n"B"\n"C"\n"F"'

# (e) quasiquote parity: a guarded match inside a macro template.
cat > "$TMP/qq.pp" <<'EOF'
defmacro pick(v) {
  quasiquote {
    match unquote(v) {
      n if n > 0 => "pos"
      _ => "nonpos"
    }
  }
}
print(pick(5))
print(pick(-2))
EOF
run_ok "guard-in-quasiquote" "$TMP/qq.pp" $'"pos"\n"nonpos"'

# (f) guardless matches are UNCHANGED — fmt round-trip stays hash-preserved for
#     a mixed guarded/guardless match (guardless arm keeps its old encoding).
cat > "$TMP/rt.ppb" <<'EOF'
def describe(r) {
  match r {
    [:ok, v] if v > 10 => "big"
    [:ok, v] => "small"
    _ => "other"
  }
}
print(describe([:ok, 50]))
EOF
"$PP" fmt --to-sexpr "$TMP/rt.ppb" > "$TMP/rt.ppl" 2>"$TMP/rt.err"
"$PP" fmt --to-braces "$TMP/rt.ppl" > "$TMP/rt2.ppb" 2>>"$TMP/rt.err"
if "$PP" --compare-hash "$TMP/rt.ppb" "$TMP/rt2.ppb" >/dev/null 2>&1; then
  ok "guarded-match-fmt-hash-preserved"
else
  bad "guarded-match-fmt-hash-preserved" "$(cat "$TMP/rt.err")"
fi

exit $fail
