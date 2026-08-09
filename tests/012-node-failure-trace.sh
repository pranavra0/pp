#!/usr/bin/env bash
# pins: LAW-28
# Regression: a node failure is a value with a trace (SPEC law 28), and a
# raising thunk is not left `Evaluating`.
#
# When a node body raises, the store records a FAILING trace — the error plus the
# reads made up to the failure. A later force with unchanged inputs re-serves the
# SAME error without re-running the body; it re-runs only when a recorded read
# changes. Before the fix, a raising thunk was left `Evaluating`, so the next
# force misreported "infinite recursion detected".
#
# Under an isolated HOME, a node
# logs "ATTEMPT" before failing, so ATTEMPT present ⇒ the body ran (miss),
# ATTEMPT absent ⇒ the failure was re-served (hit).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

check() {  # NAME  FILE  attempt=present|absent  errsubstr
  local name="$1" file="$2" amode="$3" errsub="$4"
  local ahit errok
  if grep -qE "ATTEMPT" "$file"; then ahit=present; else ahit=absent; fi
  if grep -qF "$errsub" "$file"; then errok=yes; else errok=no; fi
  if [ "$ahit" = "$amode" ] && [ "$errok" = yes ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: ATTEMPT expected $amode got $ahit; error '$errsub' present=$errok"
    cat "$file"; fail=1
  fi
}

# --- (1) failure is memoized: body runs once, same error re-served ---
rm -rf "$TMP/.pp"
cat > "$TMP/f.pp" <<'EOF'
force(node {
  perform log("ATTEMPT")
  car(5)
})
EOF
"$PP" "$TMP/f.pp" > "$TMP/o" 2>&1; check "fail-run1-miss"  "$TMP/o" present "car expects a pair"
"$PP" "$TMP/f.pp" > "$TMP/o" 2>&1; check "fail-run2-reserved" "$TMP/o" absent "car expects a pair"
# The re-served error must be the ORIGINAL, never "infinite recursion".
if grep -qi "infinite recursion" "$TMP/o"; then
  echo "FAIL d16-no-fake-recursion: re-serve reported infinite recursion"; fail=1
else
  echo "ok   d16-no-fake-recursion"
fi

# The REPL catches each line's error while retaining the node memo table.
# Repeating the byte-identical form reaches the same thunk in one process.
rm -rf "$TMP/.pp"
prog='force(node { car(5) })
force(node { car(5) })'
out=$(printf '%s\n' "$prog" | "$PP" 2>&1)
if printf '%s\n' "$out" | grep -qi "infinite recursion"; then
  echo "FAIL d16-reforce-no-fake-recursion: second force reported a cycle"; fail=1
elif [ "$(printf '%s\n' "$out" | grep -ci "car expects a pair")" -ne 2 ]; then
  echo "FAIL d16-reforce-no-fake-recursion: expected both failures"; printf '%s\n' "$out"; fail=1
else
  echo "ok   d16-reforce-no-fake-recursion"
fi

# --- (2) a failure re-runs when a recorded input changes ---
rm -rf "$TMP/.pp"
printf 'V1\n' > "$TMP/d.txt"
cat > "$TMP/fr.pp" <<EOF
force(node {
  perform log("ATTEMPT")
  slurp("$TMP/d.txt")
  car(5)
})
EOF
"$PP" --grant "fs:$TMP:ro" "$TMP/fr.pp" > "$TMP/o" 2>&1; check "failread-run1-miss"    "$TMP/o" present "car expects a pair"
"$PP" --grant "fs:$TMP:ro" "$TMP/fr.pp" > "$TMP/o" 2>&1; check "failread-run2-reserved" "$TMP/o" absent  "car expects a pair"
printf 'V2\n' > "$TMP/d.txt"
"$PP" --grant "fs:$TMP:ro" "$TMP/fr.pp" > "$TMP/o" 2>&1; check "failread-run3-rerun"    "$TMP/o" present "car expects a pair"

# --- (3) a node that succeeds after the input is fixed serves the success ---
rm -rf "$TMP/.pp"
printf 'bad\n' > "$TMP/n.txt"
cat > "$TMP/cond.pp" <<EOF
print(force(node {
  perform log("ATTEMPT")
  if slurp("$TMP/n.txt") = "ok\n" { 42 } else { car(5) }
}))
EOF
"$PP" --grant "fs:$TMP:ro" "$TMP/cond.pp" > "$TMP/o" 2>&1; check "cond-fail-first" "$TMP/o" present "car expects a pair"
printf 'ok\n' > "$TMP/n.txt"
if "$PP" --grant "fs:$TMP:ro" "$TMP/cond.pp" > "$TMP/o" 2>&1; then
  cond_status=0
else
  cond_status=$?
fi
if [ "$cond_status" -eq 0 ] &&
   grep -qE "ATTEMPT" "$TMP/o" &&
   grep -qx "42" "$TMP/o"; then
  echo "ok   cond-success-after-fix"
else
  echo "FAIL cond-success-after-fix: expected status 0, ATTEMPT trace, and exact result 42"; cat "$TMP/o"; fail=1
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== NODE-FAILURE TRACE TEST PASSED ==="; fi
exit $fail
