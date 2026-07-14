#!/usr/bin/env bash
# pins: LAW-28
# Regression: a node failure is a value with a trace (LAW 28), and a raising
# thunk is not left `Evaluating` (D16).
#
# When a node body raises, the store records a FAILING trace — the error plus the
# reads made up to the failure. A later force with unchanged inputs re-serves the
# SAME error without re-running the body; it re-runs only when a recorded read
# changes. Before the fix, a raising thunk was left `Evaluating`, so the next
# force misreported "infinite recursion detected".
#
# Tree-walker only (the store-backed backend), under an isolated HOME. A node
# logs "ATTEMPT" before failing, so ATTEMPT present ⇒ the body ran (miss),
# ATTEMPT absent ⇒ the failure was re-served (hit).
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

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
# D16: the re-served error must be the ORIGINAL, never "infinite recursion".
if grep -qi "infinite recursion" "$TMP/o"; then
  echo "FAIL d16-no-fake-recursion: re-serve reported infinite recursion"; fail=1
else
  echo "ok   d16-no-fake-recursion"
fi

# --- (2) LAW 28: failure re-runs when a recorded input changes ---
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
force(node {
  perform log("ATTEMPT")
  if slurp("$TMP/n.txt") = "ok\n" { 42 } else { car(5) }
})
EOF
"$PP" --grant "fs:$TMP:ro" "$TMP/cond.pp" > "$TMP/o" 2>&1; check "cond-fail-first" "$TMP/o" present "car expects a pair"
printf 'ok\n' > "$TMP/n.txt"
"$PP" --grant "fs:$TMP:ro" "$TMP/cond.pp" > "$TMP/o" 2>&1
if grep -qE "ATTEMPT" "$TMP/o" && ! grep -qi "car expects" "$TMP/o"; then
  echo "ok   cond-success-after-fix"
else
  echo "FAIL cond-success-after-fix"; cat "$TMP/o"; fail=1
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== NODE-FAILURE TRACE TEST PASSED ==="; fi
exit $fail
