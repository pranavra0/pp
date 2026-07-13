#!/usr/bin/env bash
# tests/025 — (def x v) / (defnode x e) value-binding semantics (ROADMAP §1).
#
# The differential suite only proves the backends AGREE; this oracle pins what
# they agree ON:
#   (a) (def x v) binds the value of v — not a nullary closure.
#   (b) The RHS runs at definition time (statement semantics), but is not
#       deep-forced: (def d (delay e)) binds an unforced thunk.
#   (c) Do-blocks are letrec*: every def in the block is in scope for the
#       whole block; touching a value binding before its def executes is an
#       error naming the binding.
#   (d) (defnode x e) binds the node thunk of e — forcing it hits the store.
#   (e) A value def's RHS referencing a name defined by a LATER top-level form
#       errors (top level is sequential for value defs).
# Both backends, isolated HOME.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

# assert_out NAME FLAGS FILE EXPECTED-STDOUT (exact match)
assert_out() {
  local name="$1" flags="$2" file="$3" expected="$4"
  local got
  got=$("$PP" $flags "$file" 2>"$TMP/err")
  if [ "$got" = "$expected" ]; then ok "$name"
  else bad "$name" "expected: $(printf '%q' "$expected")" "got:      $(printf '%q' "$got")" "stderr:   $(cat "$TMP/err")"; fi
}

# assert_err NAME FLAGS FILE PATTERN — nonzero exit and stderr matches
assert_err() {
  local name="$1" flags="$2" file="$3" pat="$4"
  if "$PP" $flags "$file" >"$TMP/out" 2>"$TMP/err"; then
    bad "$name" "expected failure, got exit 0" "$(cat "$TMP/out")"
  elif grep -qE "$pat" "$TMP/err"; then ok "$name"
  else bad "$name" "expected stderr to match: $pat" "got: $(cat "$TMP/err")"; fi
}

# ---- (a) value binding, sequential top level ----
cat > "$TMP/a.pp" <<'EOF'
let x = 5
print(x)
let y = x + 1
print(y)
def f(n) { n + x }
print(f(10))
EOF
expected=$'5\n6\n15'
assert_out "value-binding-tw" ""           "$TMP/a.pp" "$expected"
assert_out "value-binding-vm" "--bytecode" "$TMP/a.pp" "$expected"

# ---- (b) RHS runs at def time; delay is not forced ----
cat > "$TMP/b.pp" <<'EOF'
let eff = print(111)
let d = delay(print(999))
print(222)
EOF
expected=$'111\n222'
assert_out "def-time-effects-tw" ""           "$TMP/b.pp" "$expected"
assert_out "def-time-effects-vm" "--bytecode" "$TMP/b.pp" "$expected"

# ---- (c) letrec* block scope + referenced-before-definition error ----
cat > "$TMP/c.pp" <<'EOF'
def g(n) {
  def h(k) { k + m }
  let m = n * 2
  h(1) }
print(g(5))
EOF
expected="11"
assert_out "block-letrec-tw" ""           "$TMP/c.pp" "$expected"
assert_out "block-letrec-vm" "--bytecode" "$TMP/c.pp" "$expected"

cat > "$TMP/c2.pp" <<'EOF'
print(do { let a = b + 1; let b = 2
  a
})
EOF
assert_err "premature-ref-tw" ""           "$TMP/c2.pp" "b: referenced before its definition"
assert_err "premature-ref-vm" "--bytecode" "$TMP/c2.pp" "b: referenced before its definition"

# duplicate value-def name in one block is a reader error
cat > "$TMP/c3.pp" <<'EOF'
print(do { let a = 1; let a = 2; a })
EOF
assert_err "block-duplicate-def-tw" ""           "$TMP/c3.pp" "duplicate definition"
assert_err "block-duplicate-def-vm" "--bytecode" "$TMP/c3.pp" "duplicate definition"

# ---- (d) defnode binds the node thunk; forcing caches in the store ----
cat > "$TMP/d.pp" <<'EOF'
let n = node { perform log("COMPUTE"); 42 }
print(1)
print(force(n))
EOF
rm -rf "$TMP/.pp"
out=$("$PP" "$TMP/d.pp" 2>"$TMP/err")
if [ "$out" = $'1\n42' ] && grep -q "COMPUTE" "$TMP/err"; then ok "defnode-run1-computes"
else bad "defnode-run1-computes" "out: $out" "err: $(cat "$TMP/err")"; fi
out=$("$PP" "$TMP/d.pp" 2>"$TMP/err")
if [ "$out" = $'1\n42' ] && ! grep -q "COMPUTE" "$TMP/err"; then ok "defnode-run2-hits"
else bad "defnode-run2-hits" "out: $out" "err: $(cat "$TMP/err")"; fi
rm -rf "$TMP/.pp"
out=$("$PP" --bytecode "$TMP/d.pp" 2>"$TMP/err")
if [ "$out" = $'1\n42' ] && grep -q "COMPUTE" "$TMP/err"; then ok "vm-defnode-run1-computes"
else bad "vm-defnode-run1-computes" "out: $out" "err: $(cat "$TMP/err")"; fi
out=$("$PP" --bytecode "$TMP/d.pp" 2>"$TMP/err")
if [ "$out" = $'1\n42' ] && ! grep -q "COMPUTE" "$TMP/err"; then ok "vm-defnode-run2-hits"
else bad "vm-defnode-run2-hits" "out: $out" "err: $(cat "$TMP/err")"; fi

# ---- (e) top-level forward reference from a value def errors ----
cat > "$TMP/e.pp" <<'EOF'
let a = later + 1
let later = 2
EOF
assert_err "toplevel-forward-ref-tw" ""           "$TMP/e.pp" "unbound symbol: later"
assert_err "toplevel-forward-ref-vm" "--bytecode" "$TMP/e.pp" "unbound symbol: later"

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== DEF VALUE-BINDING TEST PASSED ==="; fi
exit $fail
