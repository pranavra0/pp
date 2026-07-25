#!/usr/bin/env bash
# Blob-hash desired values: the reconciler materializes from the CAS.
#
#   (blob S) ingests S into ~/.pp/store/blobs and returns its raw identity —
#   a small, hashable identity. Canonical tree file entries diff by that
#   identity WITHOUT loading bytes, materialize from the
#   store, and errors if a referenced blob is missing.
#
#   This means `rm -rf build/` then
#   re-reconcile restores the tree from the store with ZERO tool re-runs —
#   the desired tree (node-cached) carries identities, the store carries bytes.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
OUT="$TMP/build"

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

check_file() {  # NAME PATH EXPECTED
  local name="$1" path="$2" want="$3"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$want" ]; then echo "ok   $name"
  else echo "FAIL $name: $path missing or wrong content"; fail=1; fi
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

# --- (a) canonical file entries materialize by blob identity ---
cat > "$TMP/d.pp" <<'EOF'
{:tree -> {
  "a.o" -> {:kind -> :file, :mode -> 420, :blob -> blob("OBJ-BYTES")},
  "plain.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("INLINE")}
}}
EOF
rm -rf "$TMP/.pp" "$OUT"
run --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d.pp"
assert "blob-create"  "create=2" present
check_file "blob-a"   "$OUT/a.o"       "OBJ-BYTES"
check_file "blob-txt" "$OUT/plain.txt" "INLINE"
run --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d.pp"
assert "blob-null"    "create=0" present

# --- (b) rebuild-from-store: the desired tree comes from a cached node;
#         deleting the materialized tree does not rerun the node ---
cat > "$TMP/b.pp" <<'EOF'
let (obj = force(node {
  perform log("COMPILE")
  blob("TOOL-OUT")
})) { {:tree -> {"a.o" -> {:kind -> :file, :mode -> 420, :blob -> obj}}} }
EOF
rm -rf "$TMP/.pp" "$OUT"
run --grant "fs:$OUT:wo" --reconcile "$OUT" "$TMP/b.pp"
assert "c4-build-compiles" "COMPILE" present
check_file "c4-built"      "$OUT/a.o" "TOOL-OUT"
rm -rf "$OUT"
run --grant "fs:$OUT:wo" --reconcile "$OUT" "$TMP/b.pp"
assert "c4-restore-no-recompile" "COMPILE" absent
check_file "c4-restored"   "$OUT/a.o" "TOOL-OUT"

# --- (c) a dangling blob ref is a hard error, not silence ---
cat > "$TMP/bad.pp" <<'EOF'
{:tree -> {"x" -> {:kind -> :file, :mode -> 420, :blob -> "0000000000000000000000000000000000000000000000000000000000000000"}}}
EOF
run --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/bad.pp"
assert "dangling-blob-errors" "blob" present
if [ -f "$OUT/x" ]; then echo "FAIL dangling-not-written"; fail=1
else echo "ok   dangling-not-written"; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== BLOB RECONCILE TEST PASSED ==="; fi
exit $fail
