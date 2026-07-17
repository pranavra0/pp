#!/usr/bin/env bash
# Node-cache behavior tests: pure caching, staleness on file edit,
# node key laws (law 20), failure memoization, and capability gating.

# "COMPUTE" present => body ran (miss); absent => hit (SPEC law 17).
# Isolated HOME.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME  file  present|absent
  local name="$1" f="$2" mode="$3" hit
  if grep -qE "COMPUTE" "$f"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: COMPUTE expected $mode got $hit"; cat "$f"; fail=1; fi
}

# --- (1) caches a pure node across runs ---
rm -rf "$TMP/.pp"
cat > "$TMP/pure.pp" <<'EOF'
force(node {
  perform log("COMPUTE")
  42
})
EOF
"$PP" "$TMP/pure.pp" > "$TMP/o" 2>&1; assert "pure-run1-miss" "$TMP/o" present
"$PP" "$TMP/pure.pp" > "$TMP/o" 2>&1; assert "pure-run2-hit"  "$TMP/o" absent

# --- (2) staleness: edit a read file => recompute ---
rm -rf "$TMP/.pp"; printf 'V1\n' > "$TMP/d.txt"
cat > "$TMP/rd.pp" <<EOF
force(node {
  perform log("COMPUTE")
  slurp("$TMP/d.txt")
})
EOF
"$PP" --grant "fs:$TMP:ro" "$TMP/rd.pp" > "$TMP/o" 2>&1; assert "read-run1-miss" "$TMP/o" present
"$PP" --grant "fs:$TMP:ro" "$TMP/rd.pp" > "$TMP/o" 2>&1; assert "read-run2-hit"  "$TMP/o" absent
printf 'V2\n' > "$TMP/d.txt"
"$PP" --grant "fs:$TMP:ro" "$TMP/rd.pp" > "$TMP/o" 2>&1; assert "read-run3-stale" "$TMP/o" present

# --- (3) node key: unrelated global not in key; referenced free var in key ---
rm -rf "$TMP/.pp"
cat > "$TMP/g1.pp" <<'EOF'
let unrelated = 1
force(node {
  perform log("COMPUTE")
  7
})
EOF
cat > "$TMP/g2.pp" <<'EOF'
let unrelated = 2
force(node {
  perform log("COMPUTE")
  7
})
EOF
"$PP" "$TMP/g1.pp" > "$TMP/o" 2>&1; assert "law20-run1-miss"       "$TMP/o" present
"$PP" "$TMP/g2.pp" > "$TMP/o" 2>&1; assert "law20-unrelated-hit"   "$TMP/o" absent
cat > "$TMP/v1.pp" <<'EOF'
let (x = 1) {
  force(node {
    perform log("COMPUTE")
    x
  })
}
EOF
cat > "$TMP/v2.pp" <<'EOF'
let (x = 2) {
  force(node {
    perform log("COMPUTE")
    x
  })
}
EOF
rm -rf "$TMP/.pp"
"$PP" "$TMP/v1.pp" > "$TMP/o" 2>&1; assert "law20-x1-miss" "$TMP/o" present
"$PP" "$TMP/v2.pp" > "$TMP/o" 2>&1; assert "law20-x2-miss" "$TMP/o" present

# --- (4) failure memoization ---
rm -rf "$TMP/.pp"
cat > "$TMP/fail.pp" <<'EOF'
force(node {
  perform log("COMPUTE")
  car(5)
})
EOF
"$PP" "$TMP/fail.pp" > "$TMP/o" 2>&1
if grep -q "COMPUTE" "$TMP/o" && grep -q "car expects a pair" "$TMP/o"; then echo "ok   fail-run1"; else echo "FAIL fail-run1"; cat "$TMP/o"; fail=1; fi
"$PP" "$TMP/fail.pp" > "$TMP/o" 2>&1
if ! grep -q "COMPUTE" "$TMP/o" && grep -q "car expects a pair" "$TMP/o"; then echo "ok   fail-run2-reserved"; else echo "FAIL fail-run2-reserved"; cat "$TMP/o"; fail=1; fi

# --- (5) hit-time capability gate (no secret leak) ---
rm -rf "$TMP/.pp"; mkdir -p "$TMP/secret" "$TMP/other"; printf 'SECRETDATA\n' > "$TMP/secret/s.txt"
cat > "$TMP/sec.pp" <<EOF
perform log(force(node { slurp("$TMP/secret/s.txt") }))
EOF
"$PP" --grant "fs:$TMP:ro"       "$TMP/sec.pp" > "$TMP/o" 2>&1
if grep -q "SECRETDATA" "$TMP/o"; then echo "ok   cap-broad-caches"; else echo "FAIL cap-broad-caches"; cat "$TMP/o"; fail=1; fi
"$PP" --grant "fs:$TMP/other:ro" "$TMP/sec.pp" > "$TMP/o" 2>&1
if ! grep -q "SECRETDATA" "$TMP/o" && grep -q "permission denied" "$TMP/o"; then echo "ok   cap-narrow-denied"; else echo "FAIL cap-narrow-denied"; cat "$TMP/o"; fail=1; fi


rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== NODE CACHE TEST PASSED ==="; fi
exit $fail
