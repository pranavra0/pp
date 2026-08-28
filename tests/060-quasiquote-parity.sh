#!/usr/bin/env bash
# tests/060 — quasiquote template builds the correct value.
#
# A macro template written with `quasiquote { ... }` and unquote()d holes must
# build (or run to) the SAME value the equivalent ordinary code does.
# This is a brace-surface property: the bug it guards is the brace reader
# lowering `[ ... ]` inside quasiquote to a vector instead of a list, so
# a template `[a, b]` diverged from the literal `[a, b]` it stands for.
# This check uses a fixed expected-value oracle because the
# template-equals-literal relation is specific to brace syntax and cannot be
# expressed by the general property sweeps.
#
# Cases: bracket list (+ empty + splice), a list-building macro, try and
# match block templates (control forms, so correctness is only observable by
# running the expansion), postfix m[k] index (int vs keyword), and list-spread
# direct and through a macro. (Consolidates the former 060 + 061.)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run_one() {  # NAME FILE EXPECTED — must print EXPECTED
  local name="$1" file="$2" expected="$3" got
  got=$("$PP" "$file" 2>&1)
  if [ "$got" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "got:       $(printf '%q' "$got")"
  fi
}

# ---- bracket list parity: a qq bracket template builds the SAME list value
# as the equivalent literal, is a pair (list) not a vector, and handles the
# empty and splice cases. ----
cat > "$TMP/list.pp" <<'EOF'
let a = 1
let b = 2
let tmpl = quasiquote { [unquote(a), unquote(b)] }
let code = [a, b]
print(tmpl = code)
print(pair?(tmpl))
print(vector?(tmpl))
print(quasiquote { [] } = [])
let xs = [10, 20]
print(quasiquote { [0, splice(xs), 30] })
EOF
run_one "qq-bracket-builds-list" "$TMP/list.pp" $'true\ntrue\nfalse\ntrue\n(0 10 20 30)'

# A macro whose template quasiquotes a `list(...)` CALL emits list-building
# code (the head is a real callable), equal to the literal.
cat > "$TMP/macro.pp" <<'EOF'
defmacro mk-list(x, y) { quasiquote { list(unquote(x), unquote(y)) } }
print(mk-list(7, 8))
print(mk-list(7, 8) = [7, 8])
EOF
run_one "qq-list-call-macro" "$TMP/macro.pp" $'(7 8)\ntrue'

# ---- try block template: parity on both the :ok pass-through and the :err
# short-circuit arms. ----
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
let b1 = try { v <- ok_val; v + 1 }
print(a1)
print(a1 = b1)
let a2 = mk-try(err_val)
let b2 = try { v <- err_val; v + 1 }
print(a2)
print(a2 = b2)
EOF
run_one "qq-try-block" "$TMP/try.pp" $'11\ntrue\n(:err "boom")\ntrue'

# ---- match block template: parity on the matching and fall-through arms. ----
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
let b1 = match ok_val { [:ok, v] => v + 1; [:err, e] => 0 }
print(a1)
print(a1 = b1)
let a2 = mk-match(err_val)
let b2 = match err_val { [:ok, v] => v + 1; [:err, e] => 0 }
print(a2)
print(a2 = b2)
EOF
run_one "qq-match-block" "$TMP/match.pp" $'11\ntrue\n0\ntrue'

# ---- postfix m[k] index: the reader picks vector-get vs map-get from the
# static shape of the index (int literal vs keyword), inside qq as outside. ----
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
run_one "qq-index" "$TMP/index.pp" $'10\ntrue\n1\ntrue'

# ---- list spread: a qq spread template builds the same cons shape the literal
# spread does, directly and (with a callable head) through a macro. ----
cat > "$TMP/spread-value.pp" <<'EOF'
let a = 1
let rest = [2, 3]
let tmpl = quasiquote { [unquote(a), ... unquote(rest)] }
let code = [a, ...rest]
print(tmpl)
print(tmpl = code)
print(pair?(tmpl))
EOF
run_one "qq-spread-value" "$TMP/spread-value.pp" $'(1 2 3)\ntrue\ntrue'

cat > "$TMP/spread-macro.pp" <<'EOF'
defmacro mk-list-spread(x) { quasiquote { [list, unquote(x), ... [2, 3]] } }
print(mk-list-spread(1))
print(mk-list-spread(1) = [1, 2, 3])
EOF
run_one "qq-spread-macro" "$TMP/spread-macro.pp" $'(1 2 3)\ntrue'

exit $fail
