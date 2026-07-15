#!/usr/bin/env bash
# tests/061 — quasiquote sugar coverage (try / match / m[k] / list spread).
#
# Several block/sugar forms the ordinary brace parser supports did not parse
# inside quasiquote { ... } at all — a macro template couldn't contain them.
# This pins, for each of the four forms, that it (a) parses inside
# quasiquote{} on both backends, and (b) has VALUE PARITY: a quasiquote
# template with unquote()d holes must build/run to the SAME result the
# equivalent ordinary code does — on both the tree-walker ("$PP" f) and the
# bytecode VM ("$PP" --bytecode f). Modeled on tests/060-qq-list-parity.sh's
# idiom (READ that file first for the exact style being followed here).
#
# try/match are first-class control forms (not just data), so their parity
# can only be observed by actually RUNNING the expanded code — every case
# below goes through a real defmacro + call, never a bare quasiquote-value
# comparison for those two.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_both() {
  # $1: test name, $2: file, $3: expected output (both backends must match it)
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP" "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" \
        "expected: $(printf '%q' "$expected")" \
        "tw:       $(printf '%q' "$got_tw")" \
        "bc:       $(printf '%q' "$got_bc")"
  fi
}

# ---- try { ... } ----
# A macro template wrapping a caller-supplied expression in a try block must
# build/run identically to writing the same try block directly, on both the
# :ok short-circuit-through path and the :err short-circuit path.
cat > "$TMP/try.pp" <<'EOF'
defmacro mk-try(x) {
  quasiquote {
    try {
      v <- unquote(x)
      v + 1
    }
  }
}
let ok_val = [:ok, 10]
let err_val = [:err, "boom"]
let a1 = mk-try(ok_val)
let b1 = try {
  v <- ok_val
  v + 1
}
print(a1)
print(a1 = b1)
let a2 = mk-try(err_val)
let b2 = try {
  v <- err_val
  v + 1
}
print(a2)
print(a2 = b2)
EOF
run_both "qq-try-block-parity" "$TMP/try.pp" $'11\ntrue\n(:err "boom")\ntrue'

# ---- match E { pat => body; ... } ----
# Same idea: a macro template containing a match block must build/run to the
# same value as the equivalent literal match, on the matching AND the
# fall-through arm.
cat > "$TMP/match.pp" <<'EOF'
defmacro mk-match(x) {
  quasiquote {
    match unquote(x) {
      [:ok, v] => v + 1
      [:err, e] => 0
    }
  }
}
let ok_val = [:ok, 10]
let err_val = [:err, "boom"]
let a1 = mk-match(ok_val)
let b1 = match ok_val {
  [:ok, v] => v + 1
  [:err, e] => 0
}
print(a1)
print(a1 = b1)
let a2 = mk-match(err_val)
let b2 = match err_val {
  [:ok, v] => v + 1
  [:err, e] => 0
}
print(a2)
print(a2 = b2)
EOF
run_both "qq-match-block-parity" "$TMP/match.pp" $'11\ntrue\n0\ntrue'

# ---- m[k] postfix index ----
# The reader picks the accessor (vector-get vs hash-map-get) from the
# SYNTACTIC shape of the index — a literal int vs anything else — both
# outside and inside quasiquote (quasiquote mirrors that same static
# decision), so this pins both branches: an int-literal index into a
# vector, and a keyword-literal index into a map.
cat > "$TMP/index.pp" <<'EOF'
defmacro get0(m) { quasiquote { unquote(m)[0] } }
defmacro geta(m) { quasiquote { unquote(m)[:a] } }
let v = vector(10, 20, 30)
let hm = hash-map(:a, 1, :b, 2)
print(get0(v))
print(get0(v) = v[0])
print(geta(hm))
print(geta(hm) = hm[:a])
EOF
run_both "qq-index-parity" "$TMP/index.pp" $'10\ntrue\n1\ntrue'

# ---- list spread [a, ...rest] ----
# Direct value-level parity (no macro needed — [ ... ] in quasiquote builds
# a value immediately, same as tests/060): a template spread must build the
# exact cons(a, rest) shape the ordinary spread literal builds.
cat > "$TMP/spread-value.pp" <<'EOF'
let a = 1
let rest = [2, 3]
let tmpl = quasiquote { [unquote(a), ... unquote(rest)] }
let code = [a, ...rest]
print(tmpl)
print(tmpl = code)
print(pair?(tmpl))
EOF
run_both "qq-spread-value-parity" "$TMP/spread-value.pp" $'(1 2 3)\ntrue\ntrue'

# Also through a macro, where the built value becomes CODE (apply_macro's
# value_to_expr): the spread must sit in a list whose head is a real
# callable symbol (`list`, quoted bare — same convention 060's OWN macro
# test uses: `list(unquote(x), unquote(y))`, never a bare data list, since
# a macro's result must reflect back to valid syntax — the head of a data
# list of plain numbers is not a function, and that failure is real and
# unrelated to this test, the same one tests/060 sidesteps the same way).
# The spread TAIL here is a literal nested qq list, not a macro parameter: a
# macro argument is the CALLER's unevaluated SYNTAX (quote_to_value'd once),
# so passing `[2, 3]` as an arg and unquote()ing it would splice the quoted
# call-syntax `(list 2 3)`, not the runtime list `(2 3)` — a real but
# orthogonal "macros see syntax, not values" fact, not a spread-parity issue.
cat > "$TMP/spread-macro.pp" <<'EOF'
defmacro mk-list-spread(x) { quasiquote { [list, unquote(x), ... [2, 3]] } }
print(mk-list-spread(1))
print(mk-list-spread(1) = [1, 2, 3])
EOF
run_both "qq-spread-macro-parity" "$TMP/spread-macro.pp" $'(1 2 3)\ntrue'

exit $fail
