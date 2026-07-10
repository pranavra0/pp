#!/usr/bin/env bash
# Regression: the bytecode VM shares the persistent node cache (D7 closed).
#
# The VM used to compile `(node e)` exactly like `(delay e)` and never touch the
# store, so it recomputed every run while the tree-walker cached — a shipped
# feature in one backend only (LAW 36). The VM now routes node forcing through
# the same store with the same LAW 20 key, verifying traces (LAW 21), failure
# memoization (LAW 28), and hit-time capability gating (LAW 23b). Because the VM
# key is byte-identical to the tree-walker's for data free variables, the two
# backends even SHARE store entries.
#
# Isolated HOME. "COMPUTE" present ⇒ body ran (miss); absent ⇒ hit (LAW 17).
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

# --- (1) VM caches a pure node across runs ---
rm -rf "$TMP/.pp"
cat > "$TMP/pure.pp" <<'EOF'
(force (node (do (perform log "COMPUTE") 42)))
EOF
"$PP" --bytecode "$TMP/pure.pp" > "$TMP/o" 2>&1; assert "vm-pure-run1-miss" "$TMP/o" present
"$PP" --bytecode "$TMP/pure.pp" > "$TMP/o" 2>&1; assert "vm-pure-run2-hit"  "$TMP/o" absent

# --- (2) VM staleness: edit a read file ⇒ recompute ---
rm -rf "$TMP/.pp"; printf 'V1\n' > "$TMP/d.txt"
cat > "$TMP/rd.pp" <<EOF
(force (node (do (perform log "COMPUTE") (slurp "$TMP/d.txt"))))
EOF
"$PP" --bytecode --grant "fs:$TMP:ro" "$TMP/rd.pp" > "$TMP/o" 2>&1; assert "vm-read-run1-miss" "$TMP/o" present
"$PP" --bytecode --grant "fs:$TMP:ro" "$TMP/rd.pp" > "$TMP/o" 2>&1; assert "vm-read-run2-hit"  "$TMP/o" absent
printf 'V2\n' > "$TMP/d.txt"
"$PP" --bytecode --grant "fs:$TMP:ro" "$TMP/rd.pp" > "$TMP/o" 2>&1; assert "vm-read-run3-stale" "$TMP/o" present

# --- (3) VM LAW 20: unrelated global ∉ key; referenced free var ∈ key ---
rm -rf "$TMP/.pp"
cat > "$TMP/g1.pp" <<'EOF'
(def unrelated 1)
(force (node (do (perform log "COMPUTE") 7)))
EOF
cat > "$TMP/g2.pp" <<'EOF'
(def unrelated 2)
(force (node (do (perform log "COMPUTE") 7)))
EOF
"$PP" --bytecode "$TMP/g1.pp" > "$TMP/o" 2>&1; assert "vm-law20-run1-miss"       "$TMP/o" present
"$PP" --bytecode "$TMP/g2.pp" > "$TMP/o" 2>&1; assert "vm-law20-unrelated-hit"   "$TMP/o" absent
cat > "$TMP/v1.pp" <<'EOF'
(let [x 1] (force (node (do (perform log "COMPUTE") x))))
EOF
cat > "$TMP/v2.pp" <<'EOF'
(let [x 2] (force (node (do (perform log "COMPUTE") x))))
EOF
rm -rf "$TMP/.pp"
"$PP" --bytecode "$TMP/v1.pp" > "$TMP/o" 2>&1; assert "vm-law20-x1-miss" "$TMP/o" present
"$PP" --bytecode "$TMP/v2.pp" > "$TMP/o" 2>&1; assert "vm-law20-x2-miss" "$TMP/o" present

# --- (4) VM failure memoization ---
rm -rf "$TMP/.pp"
cat > "$TMP/fail.pp" <<'EOF'
(force (node (do (perform log "COMPUTE") (car 5))))
EOF
"$PP" --bytecode "$TMP/fail.pp" > "$TMP/o" 2>&1
if grep -q "COMPUTE" "$TMP/o" && grep -q "car expects a pair" "$TMP/o"; then echo "ok   vm-fail-run1"; else echo "FAIL vm-fail-run1"; cat "$TMP/o"; fail=1; fi
"$PP" --bytecode "$TMP/fail.pp" > "$TMP/o" 2>&1
if ! grep -q "COMPUTE" "$TMP/o" && grep -q "car expects a pair" "$TMP/o"; then echo "ok   vm-fail-run2-reserved"; else echo "FAIL vm-fail-run2-reserved"; cat "$TMP/o"; fail=1; fi

# --- (5) VM hit-time capability gate (no secret leak) ---
rm -rf "$TMP/.pp"; mkdir -p "$TMP/secret" "$TMP/other"; printf 'SECRETDATA\n' > "$TMP/secret/s.txt"
cat > "$TMP/sec.pp" <<EOF
(perform log (force (node (slurp "$TMP/secret/s.txt"))))
EOF
"$PP" --bytecode --grant "fs:$TMP:ro"       "$TMP/sec.pp" > "$TMP/o" 2>&1
if grep -q "SECRETDATA" "$TMP/o"; then echo "ok   vm-cap-broad-caches"; else echo "FAIL vm-cap-broad-caches"; cat "$TMP/o"; fail=1; fi
"$PP" --bytecode --grant "fs:$TMP/other:ro" "$TMP/sec.pp" > "$TMP/o" 2>&1
if ! grep -q "SECRETDATA" "$TMP/o" && grep -q "permission denied" "$TMP/o"; then echo "ok   vm-cap-narrow-denied"; else echo "FAIL vm-cap-narrow-denied"; cat "$TMP/o"; fail=1; fi

# --- (6) cross-backend key sharing (data node) ---
rm -rf "$TMP/.pp"
cat > "$TMP/shared.pp" <<'EOF'
(force (node (do (perform log "COMPUTE") 123)))
EOF
"$PP"            "$TMP/shared.pp" > "$TMP/o" 2>&1; assert "share-tw-populates" "$TMP/o" present
"$PP" --bytecode "$TMP/shared.pp" > "$TMP/o" 2>&1; assert "share-vm-hits-tw"  "$TMP/o" absent
rm -rf "$TMP/.pp"
"$PP" --bytecode "$TMP/shared.pp" > "$TMP/o" 2>&1; assert "share-vm-populates" "$TMP/o" present
"$PP"            "$TMP/shared.pp" > "$TMP/o" 2>&1; assert "share-tw-hits-vm"   "$TMP/o" absent

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== VM NODE PARITY TEST PASSED ==="; fi
exit $fail
