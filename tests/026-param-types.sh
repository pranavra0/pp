#!/usr/bin/env bash
# tests/026 — per-parameter type annotations are CHECKED: they used to
# parse and then be silently discarded. The reader desugars `(def (f x :
# int) body)` into a located type check on `x` ahead of the body, so the
# tree-walker enforces:
#   (a) a well-typed call passes and returns the body's value;
#   (b) an ill-typed call raises a "type mismatch" error, with the
#       definition-site location;
#   (c) unknown type names are a hard error;
#   (d) vector param lists ([x : int]) and multi-param lists check too;
#   (e) return-type + param-type combine.
# pins: LAW-32
set -uo pipefail
. "$(dirname "$0")/lib.sh"
assert_out() {
  local name="$1" flags="$2" file="$3" expected="$4"
  local got
  got=$("$PP" $flags "$file" 2>"$TMP/err")
  if [ "$got" = "$expected" ]; then ok "$name"
  else bad "$name" "expected: $(printf '%q' "$expected")" "got: $(printf '%q' "$got")" "stderr: $(cat "$TMP/err")"; fi
}

assert_err() {
  local name="$1" flags="$2" file="$3" pat="$4"
  if "$PP" $flags "$file" >"$TMP/out" 2>"$TMP/err"; then
    bad "$name" "expected failure, got exit 0" "$(cat "$TMP/out")"
  elif grep -qE "$pat" "$TMP/err"; then ok "$name"
  else bad "$name" "expected stderr to match: $pat" "got: $(cat "$TMP/err")"; fi
}

# ---- (a) well-typed calls pass ----
cat > "$TMP/a.pp" <<'EOF'
def f(x: int) { x + 1 }
print(f(41))
def g(a: int, b: string) { string-length(b) }
print(g(1, "abc"))
print((fn(x: int) { x * 2 })(21))
EOF
expected=$'42\n3\n42'
assert_out "well-typed" ""           "$TMP/a.pp" "$expected"

# ---- (b) ill-typed call errors with the def-site location, identically ----
cat > "$TMP/b.pp" <<'EOF'
def f(x: int) { x + 1 }
print(f("oops"))
EOF
pat='type mismatch: expected int, got .*oops.* at .*b\.pp:1'
assert_err "ill-typed" ""           "$TMP/b.pp" "$pat"

# ---- (c) unknown type names are a hard error ----
cat > "$TMP/c.pp" <<'EOF'
def h(x: widget) { x }
print(h(7))
EOF
assert_err "unknown-type-err" ""           "$TMP/c.pp" "type mismatch: expected widget, got 7 at .*c\.pp:1"

# ---- (d) vector param list checks ----
cat > "$TMP/d.pp" <<'EOF'
let v = fn(s: string) { string-length(s) }
print(v(5))
EOF
assert_err "vector-param" ""           "$TMP/d.pp" "type mismatch: expected string, got 5"

# ---- (e) return type + param type combine ----
cat > "$TMP/e.pp" <<'EOF'
def r(x: int): string { string-append("n=", "x") }
print(r(3))
def bad(x: int): string { x }
print(bad(3))
EOF
if out=$("$PP" "$TMP/e.pp" 2>"$TMP/err"); then
  bad "ret-and-param" "expected failure" "$out"
else
  if [ "$out" = '"n=x"' ] && grep -q 'type mismatch: expected string, got 3' "$TMP/err"; then
    ok "ret-and-param"
  else bad "ret-and-param" "out: $out" "err: $(cat "$TMP/err")"; fi
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== PARAM TYPE ANNOTATION TEST PASSED ==="; fi
exit $fail
