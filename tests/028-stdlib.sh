#!/usr/bin/env bash
# tests/028 — stdlib oracle: expected VALUES for the new primitives, plus
# the pieces that need process-level setup:
#   (a) string/number primitives produce the right values (not just parity);
#   (b) `$argv`: everything after `--` on the CLI is a list of strings;
#   (c) `$env` reads the environment, nil when absent;
#   (d) exit-code control: (exit N) terminates the run with code N;
#   (e) assert failures report the failing form and its file:line;
#   (f) `$stat` is a capability-gated observation recorded as a stat: trace
#       cell inside nodes; create/delete invalidates, and no grant denies.
# Isolated HOME.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
assert_out() {  # NAME FLAGS FILE EXPECTED [ARGS...]
  local name="$1" flags="$2" file="$3" expected="$4"; shift 4
  local got
  got=$("$PP" $flags "$file" "$@" 2>"$TMP/err")
  if [ "$got" = "$expected" ]; then ok "$name"
  else bad "$name" "expected: $(printf '%q' "$expected")" "got: $(printf '%q' "$got")" "stderr: $(cat "$TMP/err")"; fi
}

# ---- (a) value oracle for string/number primitives ----
cat > "$TMP/a.pp" <<'EOF'
print(number->string(42))
print(string->number("42"))
print(string-index("hello world", "world"))
print(string-index("hello", "zz"))
print(string-trim("  x  "))
print(string-sub("abcdef", 1, 3))
EOF
expected=$'"42"\n42\n6\nnil\n"x"\n"bcd"'
assert_out "string-prims" ""           "$TMP/a.pp" "$expected"

# ---- (b) argv ----
cat > "$TMP/b.pp" <<'EOF'
print($argv())
EOF
expected='("x" "y z" "3")'
assert_out "argv" ""           "$TMP/b.pp" "$expected" -- x "y z" 3
assert_out "argv-empty" ""     "$TMP/b.pp" "nil"

# ---- (c) environment observation ----
cat > "$TMP/c.pp" <<'EOF'
print($env("PP_TEST_VAR"))
print($env("PP_DEFINITELY_UNSET_VAR"))
EOF
expected=$'"hello"\nnil'
PP_TEST_VAR=hello assert_out "env-observation" ""    "$TMP/c.pp" "$expected"

# ---- (d) exit-code control ----
cat > "$TMP/d.pp" <<'EOF'
print(1)
exit(3)
print(2)
EOF
out=$("$PP" "$TMP/d.pp" 2>"$TMP/err"); ec=$?
if [ "$ec" -eq 3 ] && [ "$out" = "1" ]; then ok "exit-code"
else bad "exit-code" "exit=$ec out=$out err=$(cat "$TMP/err")"; fi

# ---- (e) assert failure reports form + location ----
cat > "$TMP/e.pp" <<'EOF'
let x = 2
assert(x = 1)
EOF
if "$PP" "$TMP/e.pp" >"$TMP/out" 2>"$TMP/err"; then
  bad "assert-fails" "expected failure"
elif grep -qE 'assertion failed: \(= x 1\) at .*e\.pp:2' "$TMP/err"; then
  ok "assert-fails"
else bad "assert-fails" "stderr: $(cat "$TMP/err")"; fi
cat > "$TMP/e2.pp" <<'EOF'
assert(false, "the sky is falling")
EOF
if "$PP" "$TMP/e2.pp" >"$TMP/out" 2>"$TMP/err"; then
  bad "assert-custom-msg" "expected failure"
elif grep -qE 'the sky is falling at .*e2\.pp:1' "$TMP/err"; then
  ok "assert-custom-msg"
else bad "assert-custom-msg" "stderr: $(cat "$TMP/err")"; fi

# ---- (f) file predicates: gated + stat: trace cells ----
cat > "$TMP/f.pp" <<EOF
print(force(node {
  log!("COMPUTE"); not(nil?(\$stat("$TMP/probe"))) }))
print(\$stat("$TMP") = :directory)
print(\$stat("$TMP/probe") = :directory)
EOF
G=(--grant "fs:$TMP:ro")
rm -rf "$TMP/.pp" "$TMP/probe"
run_f() { "$PP" "$@" "$TMP/f.pp" > "$TMP/o" 2>"$TMP/errf"; }
run_f "${G[@]}"
if [ "$(cat "$TMP/o")" = $'false\ntrue\nfalse' ] && grep -q COMPUTE "$TMP/errf"; then
  ok "stat-run1-absent"
else bad "stat-run1-absent" "$(cat "$TMP/o")" "$(cat "$TMP/errf")"; fi
run_f "${G[@]}"
if ! grep -q COMPUTE "$TMP/errf"; then ok "stat-run2-hit"
else bad "stat-run2-hit"; fi
touch "$TMP/probe"
run_f "${G[@]}"
if [ "$(head -1 "$TMP/o")" = "true" ] && grep -q COMPUTE "$TMP/errf"; then
  ok "stat-run3-created-recomputes"
else bad "stat-run3-created-recomputes" "$(cat "$TMP/o")" "$(cat "$TMP/errf")"; fi
rm "$TMP/probe"
run_f "${G[@]}"
if [ "$(head -1 "$TMP/o")" = "false" ] && ! grep -q COMPUTE "$TMP/errf"; then
  ok "stat-run4-absent-trace-rehits"
else bad "stat-run4-absent-trace-rehits" "$(cat "$TMP/o")" "$(cat "$TMP/errf")"; fi
# no grant ⇒ capability error naming the operation
if "$PP" "$TMP/f.pp" >"$TMP/o" 2>"$TMP/errf"; then
  bad "stat-no-grant-denied" "expected failure"
elif grep -q '\$stat: filesystem read not granted' "$TMP/errf"; then
  ok "stat-no-grant-denied"
else bad "stat-no-grant-denied" "$(cat "$TMP/errf")"; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== STDLIB TEST PASSED ==="; fi
exit $fail
