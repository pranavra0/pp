#!/usr/bin/env bash
# tests/082 — C2: call spread. `f(a, ...rest, b)` — a spread anywhere in an
# argument list — lowers to `apply(f, list(a), rest, list(b))`; the `apply`
# primitive (evaluator) concatenates the segments and calls f. Spread-free
# calls keep the ordinary `EApply` shape. Checked, plus a quasiquote template
# and the bare `apply` primitive directly.
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

# (a) trailing spread into a variadic builtin.
cat > "$TMP/trail.pp" <<'EOF'
let xs = [1, 2, 3]
print(list(0, ...xs))
EOF
run_ok "trailing-spread" "$TMP/trail.pp" '(0 1 2 3)'

# (b) mid-list spread (the showcase's run! shape).
cat > "$TMP/mid.pp" <<'EOF'
let xs = [1, 2, 3]
print(list("a", ...xs, "z"))
EOF
run_ok "mid-list-spread" "$TMP/mid.pp" '("a" 1 2 3 "z")'

# (c) leading spread.
cat > "$TMP/lead.pp" <<'EOF'
let xs = [1, 2, 3]
print(list(...xs, 99))
EOF
run_ok "leading-spread" "$TMP/lead.pp" '(1 2 3 99)'

# (d) spread-only.
cat > "$TMP/only.pp" <<'EOF'
let xs = [1, 2, 3]
print(list(...xs))
EOF
run_ok "spread-only" "$TMP/only.pp" '(1 2 3)'

# (e) multiple spreads concatenate in order.
cat > "$TMP/multi.pp" <<'EOF'
let xs = [1, 2]
let ys = [7, 8]
print(list(...xs, ...ys, 100))
EOF
run_ok "multiple-spreads" "$TMP/multi.pp" '(1 2 7 8 100)'

# (f) spread into a FIXED-arity closure (arity satisfied exactly).
cat > "$TMP/fixed.pp" <<'EOF'
def add3(a, b, c) { a + b + c }
let xs = [1, 2, 3]
print(add3(...xs))
EOF
run_ok "spread-into-fixed-arity" "$TMP/fixed.pp" '6'

# (g) the `apply` primitive directly: (apply f seg…) concatenates and calls.
cat > "$TMP/apply.pp" <<'EOF'
def add3(a, b, c) { a + b + c }
print(apply(add3, [10, 20, 30]))
print(apply(list, [1, 2], [3, 4]))
EOF
run_ok "apply-primitive" "$TMP/apply.pp" $'60\n(1 2 3 4)'

# (h) spread-free calls are unaffected (still plain application).
cat > "$TMP/plain.pp" <<'EOF'
print(list(1, 2, 3))
EOF
run_ok "spread-free-unchanged" "$TMP/plain.pp" '(1 2 3)'

# (i) quasiquote parity: a template with a spread argument builds the same
#     apply-lowered call after expansion (the spaced `... expr` form, matching
#     list-literal spread of a compound target).
cat > "$TMP/qq.pp" <<'EOF'
defmacro callwith(pre, rest) {
  quasiquote {
    list(unquote(pre), ... unquote(rest))
  }
}
let xs = [2, 3]
print(callwith(1, xs))
EOF
run_ok "call-spread-in-quasiquote" "$TMP/qq.pp" '(1 2 3)'

# (j) apply of a non-list segment errors cleanly.
cat > "$TMP/bad.pp" <<'EOF'
print(apply(list, 5))
EOF
got=$("$PP" "$TMP/bad.pp" 2>&1 || true)
if [[ "$got" == *error* ]]; then
  ok "apply-non-list-errors"
else
  bad "apply-non-list-errors" "got: $got"
fi

exit $fail
