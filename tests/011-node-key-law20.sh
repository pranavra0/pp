#!/usr/bin/env bash
# Regression: the persistent node key is LAW 20 — H(code ‖ free-var value hashes)
# — not the Phase-0 whole-environment hash.
#
# The old key folded in `env.env_hash`, so defining or rebinding ANY global (even
# one the node never references) changed the key and needlessly invalidated every
# cached node. LAW 20 keys a node on its code plus the *values* of the free
# variables it actually references, so:
#   - rebinding an unrelated global is a cache HIT (identity unchanged), and
#   - changing a referenced free variable's value is a MISS (identity changed).
# The capability set is deliberately excluded from the key (authority gates a hit
# at verify time — LAW 23 — it never renames the result).
#
# Runs under an isolated HOME (tree-walker only, the sole backend with a store).
# A node logs "COMPUTE" on the miss; per LAW 17 a hit does not replay it, so the
# presence/absence of COMPUTE tells miss from hit.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME  FILE  present|absent
  local name="$1" file="$2" mode="$3"
  if grep -qE "COMPUTE" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: COMPUTE expected $mode, got $hit"; cat "$file"; fail=1; fi
}

# --- (a) an unrelated global must NOT invalidate the node ---
rm -rf "$TMP/.pp"
cat > "$TMP/a1.pp" <<'EOF'
(def unrelated 1)
(force (node (do (perform log "COMPUTE") 42)))
EOF
cat > "$TMP/a2.pp" <<'EOF'
(def unrelated 99999)
(force (node (do (perform log "COMPUTE") 42)))
EOF
"$PP" "$TMP/a1.pp" > "$TMP/o" 2>&1; assert "unrelated-run1-miss"       "$TMP/o" present
"$PP" "$TMP/a2.pp" > "$TMP/o" 2>&1; assert "unrelated-rebind-still-hit" "$TMP/o" absent

# --- (b) changing a REFERENCED free variable must re-key ---
rm -rf "$TMP/.pp"
cat > "$TMP/c1.pp" <<'EOF'
(let [x 1] (force (node (do (perform log "COMPUTE") x))))
EOF
cat > "$TMP/c2.pp" <<'EOF'
(let [x 2] (force (node (do (perform log "COMPUTE") x))))
EOF
"$PP" "$TMP/c1.pp" > "$TMP/o" 2>&1; assert "freevar-x1-miss"      "$TMP/o" present
"$PP" "$TMP/c2.pp" > "$TMP/o" 2>&1; assert "freevar-x2-miss"      "$TMP/o" present
"$PP" "$TMP/c1.pp" > "$TMP/o" 2>&1; assert "freevar-x1-revert-hit" "$TMP/o" absent

# --- (c) widening the capability grant must NOT invalidate (caps ∉ key) ---
rm -rf "$TMP/.pp"
printf 'DATA\n' > "$TMP/f.txt"
cat > "$TMP/cap.pp" <<EOF
(force (node (do (perform log "COMPUTE") (slurp "$TMP/f.txt"))))
EOF
"$PP" --grant "fs:$TMP:ro"  "$TMP/cap.pp" > "$TMP/o" 2>&1; assert "cap-narrow-miss" "$TMP/o" present
"$PP" --grant "fs:/:ro"     "$TMP/cap.pp" > "$TMP/o" 2>&1; assert "cap-widen-hit"   "$TMP/o" absent

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== NODE-KEY LAW20 TEST PASSED ==="; fi
exit $fail
