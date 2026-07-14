#!/usr/bin/env bash
# tests/076 — Phase B surface removals: the deleted forms must no longer parse,
# and the forms that replace or survive them must still work identically on
# both backends.
#
#   B8  @ attributes           (@cache/@needs/@reads/@deprecated)  -> parse error
#   B7  postfix ? unwrap        (expr? / let x = expr?)             -> parse error
#   B6  cond {}                 (cond { t => r; ... })              -> gone
#   B1  cell literals           (file:"P" / env:"N" / tree:"R")     -> parse error
#
# Preserved / replacement forms exercised on both backends:
#   - try {} with `<-` propagation and a plain `let x = e` sequential binding
#   - $file(...) observation (the one observation surface)
#
# Differential: the tree-walker and the bytecode VM must agree byte for byte.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

# A removed form must produce a parse error mentioning $needle, identically on
# both backends (both must fail; both must contain the needle).
run_removed() {
  local name="$1" src="$2" needle="$3"
  printf '%s\n' "$src" > "$TMP/case.pp"
  local out_tw out_bc rc_tw rc_bc
  out_tw=$("$PP" "$TMP/case.pp" 2>&1); rc_tw=$?
  out_bc=$("$PP" --bytecode "$TMP/case.pp" 2>&1); rc_bc=$?
  if [ $rc_tw -eq 0 ] || [ $rc_bc -eq 0 ]; then
    bad "$name" "expected a parse error, but it parsed" \
        "tw(rc=$rc_tw): $out_tw" "bc(rc=$rc_bc): $out_bc"
    return
  fi
  if [[ "$out_tw" == *"$needle"* ]] && [[ "$out_bc" == *"$needle"* ]]; then
    ok "$name"
  else
    bad "$name" "error text missing needle '$needle'" \
        "tw: $out_tw" "bc: $out_bc"
  fi
}

# A preserved form must succeed and agree byte for byte across backends.
run_ok() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP" "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")" \
        "expected: $(printf '%q' "$expected")"
  fi
}

# ---- B8: @ attributes ----
run_removed "B8-at-cache-rejected"  '@cache def f() { 1 }'          "not part of the language"
run_removed "B8-at-needs-rejected"  '@needs(process) node h() { 1 }' "not part of the language"

# ---- B7: postfix ? (the `?` only tokenizes separately after `)`/`]`) ----
run_removed "B7-bare-postfix-q" \
  'def f(r) { try { identity(r)? } }'                               "postfix"
run_removed "B7-let-postfix-q" \
  'def f(r) { try { let v = identity(r)? ; [:ok, v] } }'            "postfix"

# ---- B1: cell literals ----
run_removed "B1-file-literal"  'print(file:"x")'                    ":"
run_removed "B1-env-literal"   'print(env:"CC")'                    ":"

# ---- B6: cond is now an ordinary identifier (no cond {} form) ----
# Using `cond` as a variable name must work — proving the special form is gone.
cat > "$TMP/cond-ident.pp" <<'EOF'
let cond = 42
print(cond)
EOF
run_ok "B6-cond-is-ordinary-identifier" "$TMP/cond-ident.pp" '42'

# ---- preserved: try {} with <- and a plain let binding ----
cat > "$TMP/try-ok.pp" <<'EOF'
def safe-div(a, b) { if b = 0 { [:err, "div0"] } else { [:ok, a / b] } }
def compute(x, y) {
  try {
    a <- safe-div(x, y)
    let doubled = a * 2
    b <- safe-div(doubled, 1)
    [:ok, a + b]
  }
}
print(compute(10, 2))
print(compute(10, 0))
EOF
run_ok "B7-try-with-plain-let-and-propagation" "$TMP/try-ok.pp" $'(:ok 15)\n(:err "div0")'

# ---- preserved: the $ family is the one observation surface ----
# $env observes the world without a path capability; proves the family works
# after the cell-literal token was removed. ($file/$glob/$secret parse the same
# way — pinned by tests/066/074.)
export B1_VAR="observed"
cat > "$TMP/dollar-env.pp" <<'EOF'
print($env("B1_VAR"))
print($env("B1_MISSING", "fallback"))
EOF
run_ok "B1-dollar-env-observes" "$TMP/dollar-env.pp" $'"observed"\n"fallback"'

exit $fail
