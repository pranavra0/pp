#!/usr/bin/env bash
# tests/027 — error-message ergonomics (ROADMAP §1, LAW 29 / D12):
#   (a) a runtime error escaping ANY top-level form reports that form's
#       file:line (not just def/fn bodies), identically in both backends;
#   (b) arity errors name the function being called;
#   (c) capability errors name the operation;
#   (d) unbound-symbol errors carry the location and identical text;
#   (e) an error that already carries a location is not double-located;
#   (f) uncaught errors print as one clean "pp: error: …" line, exit 1.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

# assert_err NAME FILE PATTERN — both backends fail, stderr matches PATTERN,
# and the two backends' stderr is byte-identical.
assert_err_both() {
  local name="$1" file="$2" pat="$3"
  local ec1=0 ec2=0
  "$PP" "$file" >"$TMP/o1" 2>"$TMP/e1" || ec1=$?
  "$PP" --bytecode "$file" >"$TMP/o2" 2>"$TMP/e2" || ec2=$?
  if [ "$ec1" -eq 0 ] || [ "$ec2" -eq 0 ]; then
    bad "$name" "expected both backends to fail (tw=$ec1 vm=$ec2)"
    return
  fi
  if ! grep -qE "$pat" "$TMP/e1"; then
    bad "$name" "tw stderr did not match: $pat" "got: $(cat "$TMP/e1")"
    return
  fi
  if ! diff -q "$TMP/e1" "$TMP/e2" >/dev/null; then
    bad "$name" "backends' stderr differs" "tw: $(cat "$TMP/e1")" "vm: $(cat "$TMP/e2")"
    return
  fi
  ok "$name"
}

# ---- (a) arbitrary top-level expression errors carry file:line ----
cat > "$TMP/a.pp" <<'EOF'
def f(x) { x + 1 }
print(f(1))
car(5)
EOF
assert_err_both "toplevel-location" "$TMP/a.pp" 'car expects a pair at .*a\.pp:3'

# ---- (b) arity errors name the function ----
cat > "$TMP/b.pp" <<'EOF'
def g(x) { x }
g(1, 2)
EOF
assert_err_both "arity-names-fn" "$TMP/b.pp" 'arity mismatch calling g: expected 1 args, got 2 at .*b\.pp:2'

cat > "$TMP/b2.pp" <<'EOF'
(fn(x) { x })(1, 2)
EOF
assert_err_both "arity-anon-fn" "$TMP/b2.pp" 'arity mismatch calling #<fn>: expected 1 args, got 2 at .*b2\.pp:1'

# ---- (c) capability errors name the operation ----
cat > "$TMP/c.pp" <<'EOF'
perform read-file("/etc/hosts")
EOF
assert_err_both "cap-names-operation" "$TMP/c.pp" 'read-file: capability error: no read access for /etc/hosts at .*c\.pp:1'

# ---- (d) unbound symbols: same text + location in both backends ----
cat > "$TMP/d.pp" <<'EOF'
print(nosuchvar)
EOF
assert_err_both "unbound-location" "$TMP/d.pp" 'unbound symbol: nosuchvar at .*d\.pp:1'

# ---- (e) already-located errors are not double-located ----
cat > "$TMP/e.pp" <<'EOF'
def h(x: int) { x }
h("s")
EOF
"$PP" "$TMP/e.pp" >/dev/null 2>"$TMP/e1" || true
n_at=$(grep -o " at " "$TMP/e1" | wc -l | tr -d ' ')
if [ "$n_at" = "1" ]; then ok "no-double-location"
else bad "no-double-location" "expected exactly one ' at ', got $n_at: $(cat "$TMP/e1")"; fi

# ---- (f) clean single-line report, exit code 1 ----
ec=0; "$PP" "$TMP/a.pp" >/dev/null 2>"$TMP/e1" || ec=$?
if [ "$ec" -eq 1 ] && grep -q '^pp: error: ' "$TMP/e1" && ! grep -q "Fatal error" "$TMP/e1"; then
  ok "clean-error-line"
else bad "clean-error-line" "exit=$ec" "stderr: $(cat "$TMP/e1")"; fi

# ---- (g) an error inside a `load`ed file cites THAT file's line, not the
# loading form's (D12 residual, closed) — both backends, byte-identical ----
cat > "$TMP/g-inner.pp" <<'EOF'
print("inner-before")
car(5)
EOF
# Unquoted heredoc: embed $TMP as an absolute load path so this case does not
# depend on cwd (loader authority resolves relative paths against cwd, not
# the loading file's directory — tests/020).
cat > "$TMP/g-outer.pp" <<EOF
print("outer-before")
load("$TMP/g-inner.pp")
EOF
assert_err_both "loaded-file-location" "$TMP/g-outer.pp" 'car expects a pair at .*g-inner\.pp:2'

# ---- (h) M7 S4: LAW 29 error text is byte-identical across surfaces — the
# SAME program (case (a)'s toplevel-location), authored in .ppl (the sexpr/
# AST surface, still fully supported) instead of the now-default brace
# surface, produces the identical message text modulo only the file name ----
cat > "$TMP/a.ppl" <<'EOF'
(def (f x) (+ x 1))
(print (f 1))
(car 5)
EOF
err_pp=$("$PP" "$TMP/a.pp" 2>&1 >/dev/null | sed 's/a\.pp:/a.X:/')
err_ppl=$("$PP" "$TMP/a.ppl" 2>&1 >/dev/null | sed 's/a\.ppl:/a.X:/')
if [ "$err_pp" = "$err_ppl" ] && printf '%s' "$err_ppl" | grep -qE 'car expects a pair at .*a\.X:3'; then
  ok "error-text-parity-ppl"
else
  bad "error-text-parity-ppl" "pp:  $err_pp" "ppl: $err_ppl"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== ERROR MESSAGE TEST PASSED ==="; fi
exit $fail
