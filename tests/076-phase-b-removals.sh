#!/usr/bin/env bash
# tests/076 — four removed surface forms must no longer parse, and the forms
# that replace or survive them must still work.
#
#   @ attributes           (@cache/@needs/@reads/@deprecated)  -> parse error
#   postfix ? unwrap        (expr? / let x = expr?)             -> parse error
#   cond {}                 (cond { t => r; ... })              -> gone
#   cell literals           (file:"P" / env:"N" / tree:"R")     -> parse error
#
# Preserved / replacement forms exercised:
#   - try {} with `<-` propagation and a plain `let x = e` sequential binding
#   - $file(...) observation (the one observation surface)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# A removed form must produce a parse error mentioning $needle.
run_removed() {
  local name="$1" src="$2" needle="$3"
  printf '%s\n' "$src" > "$TMP/case.pp"
  local out rc
  out=$("$PP" "$TMP/case.pp" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    bad "$name" "expected a parse error, but it parsed" "out: $out"
    return
  fi
  if [[ "$out" == *"$needle"* ]]; then
    ok "$name"
  else
    bad "$name" "error text missing needle '$needle'" "out: $out"
  fi
}

# A preserved form must succeed and produce the expected output.
run_ok() {
  local name="$1" file="$2" expected="$3"
  local got
  got=$("$PP" "$file" 2>&1)
  if [ "$got" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "got: $(printf '%q' "$got")" "expected: $(printf '%q' "$expected")"
  fi
}

run_unbound() {
  local name="$1" src="$2" symbol="$3"
  printf '%s\n' "$src" > "$TMP/case.pp"
  local out
  out=$("$PP" "$TMP/case.pp" 2>&1)
  if [[ "$out" == *"unbound symbol: $symbol"* ]]; then
    ok "$name"
  else
    bad "$name" "expected unbound symbol: $symbol" "out: $out"
  fi
}

# ---- @ attributes are rejected as unknown syntax (case B8 below) ----
run_removed "B8-at-cache-rejected"  '@cache def f() { 1 }'          "not part of the language"
run_removed "B8-at-needs-rejected"  '@needs(process) node h() { 1 }' "not part of the language"

# ---- postfix ? unwrap is rejected; `?` only tokenizes separately after
# `)`/`]` (case B7 below) ----
run_removed "B7-bare-postfix-q" \
  'def f(r) { try { identity(r)? } }'                               "postfix"
run_removed "B7-let-postfix-q" \
  'def f(r) { try { let v = identity(r)? ; [:ok, v] } }'            "postfix"

# ---- cell literals are rejected as parse errors (case B1 below) ----
run_removed "B1-file-literal"  'print(file:"x")'                    ":"
run_removed "B1-env-literal"   'print(env:"CC")'                    ":"

# ---- cond is now an ordinary identifier; there is no cond {} form (case B6
#      below) ----
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
# after the cell-literal token was removed. ($file/$tree/$secret parse the same
# way — pinned by tests/066/074.)
export B1_VAR="observed"
cat > "$TMP/dollar-env.pp" <<'EOF'
print($env("B1_VAR"))
print($env("B1_MISSING", "fallback"))
EOF
run_ok "B1-dollar-env-observes" "$TMP/dollar-env.pp" $'"observed"\n"fallback"'

# ---- removed: raw observation callables have no compatibility bindings ----
run_unbound "raw-slurp-removed"        'slurp("x")'       "slurp"
run_unbound "raw-env-get-removed"      'env-get("x")'     "env-get"
run_unbound "raw-probe-removed"        'probe("x")'       "probe"
run_unbound "raw-config-removed"        'config("x")'      "config"
run_unbound "raw-argv-removed"         'argv()'           "argv"
run_unbound "raw-file-exists-removed"  'file-exists?("x")' "file-exists?"
run_unbound "raw-dir-removed"          'dir?("x")'        "dir?"
run_unbound "raw-tree-observe-removed" 'tree-observe("x")' "tree-observe"

exit $fail
