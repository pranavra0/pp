#!/usr/bin/env bash
# Q4 / LAW 30: filesystem-domain reconciler v1 — desired state, single writer.
#
#   pp --reconcile ROOT prog.pp takes the program's final value — a map of
#   relative paths to string contents — as the DESIRED state of the domain
#   rooted at ROOT, and makes reality match it:
#     - plan  = diff desired against observed (content hashes);
#     - apply = temp-file + rename materialization (atomic), parents created;
#     - files under ROOT not in the desired map are deleted (single writer —
#       the domain is managed, the grant is the consent);
#     - verify-after-write re-reads every written file;
#     - an intent/done pair is journaled to ~/.pp/store/journal before/after
#       the apply (Q4 crash-safety: recovery is re-running reconcile).
#   Authority: an fs WRITE grant over ROOT is required; no grant, no writes.
#   Stratification (LAW 30): a program whose evaluation READ its own domain
#   (any file:/tree: observation under ROOT) is an error — otherwise
#   reconcile loops forever.
#
# Runs under an isolated HOME; both backends.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
OUT="$TMP/outroot"
fail=0

assert() {  # NAME PATTERN present|absent  (matches $TMP/out)
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

check_file() {  # NAME PATH EXPECTED-CONTENT
  local name="$1" path="$2" want="$3"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$want" ]; then echo "ok   $name"
  else echo "FAIL $name: $path missing or wrong content"; fail=1; fi
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

cat > "$TMP/d1.pp" <<'EOF'
{"a.txt" -> "A1", "sub/b.txt" -> string-append("B", "1")}
EOF
cat > "$TMP/d2.pp" <<'EOF'
{"a.txt" -> "A2"}
EOF

# --- (a) no write grant ⇒ capability error, nothing materialized ---
run --reconcile "$OUT" "$TMP/d1.pp"
assert "nogrant-denied" "apability" present
if [ -e "$OUT/a.txt" ]; then echo "FAIL nogrant-no-write: a.txt exists"; fail=1
else echo "ok   nogrant-no-write"; fi

# --- (b) first reconcile creates the tree ---
run --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d1.pp"
assert "create-summary"  "create=2"  present
check_file "create-a"    "$OUT/a.txt"      "A1"
check_file "create-b"    "$OUT/sub/b.txt"  "B1"

# --- (c) null reconcile: reality already matches ⇒ zero writes ---
run --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d1.pp"
assert "null-create"     "create=0"  present
assert "null-update"     "update=0"  present
assert "null-delete"     "delete=0"  present

# --- (d) drift converges: manual edit is overwritten, a foreign file under
#         the managed root is removed (single writer) ---
printf 'TAMPERED' > "$OUT/a.txt"
printf 'foreign'  > "$OUT/stray.txt"
run --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d1.pp"
assert "drift-update"    "update=1"  present
assert "drift-delete"    "delete=1"  present
check_file "drift-a"     "$OUT/a.txt" "A1"
if [ -e "$OUT/stray.txt" ]; then echo "FAIL drift-stray-removed: stray.txt survived"; fail=1
else echo "ok   drift-stray-removed"; fi

# --- (e) desired shrinks: removed entries are deleted from the domain ---
run --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d2.pp"
assert "shrink-update"   "update=1"  present
assert "shrink-delete"   "delete=1"  present
check_file "shrink-a"    "$OUT/a.txt" "A2"
if [ -e "$OUT/sub/b.txt" ]; then echo "FAIL shrink-b-gone: sub/b.txt survived"; fail=1
else echo "ok   shrink-b-gone"; fi

# --- (f) journal: every apply leaves an intent/done pair ---
if [ -d "$TMP/.pp/store/journal" ] && grep -q "intent" "$TMP/.pp/store/journal/log" \
   && grep -q "done" "$TMP/.pp/store/journal/log"; then
  echo "ok   journal-intent-done"
else
  echo "FAIL journal-intent-done: journal missing or incomplete"; fail=1
fi

# --- (g) stratification (LAW 30): desired state may not read its own domain ---
cat > "$TMP/strat.pp" <<EOF
{"a.txt" -> slurp("$OUT/a.txt")}
EOF
run --grant "fs:$OUT:rw" --grant "fs:$OUT:ro" --reconcile "$OUT" "$TMP/strat.pp"
assert "stratification-error" "tratification" present
check_file "stratification-untouched" "$OUT/a.txt" "A2"

# --- (h) VM parity ---
rm -rf "$OUT"
run --bytecode --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d1.pp"
assert "vm-create-summary" "create=2" present
check_file "vm-create-a"   "$OUT/a.txt"     "A1"
check_file "vm-create-b"   "$OUT/sub/b.txt" "B1"
run --bytecode --grant "fs:$OUT:rw" --reconcile "$OUT" "$TMP/d1.pp"
assert "vm-null"           "create=0" present

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== RECONCILER (Q4) TEST PASSED ==="; fi
exit $fail
