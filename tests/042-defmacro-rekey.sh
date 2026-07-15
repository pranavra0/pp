#!/usr/bin/env bash
# A macro EDIT — same call sites, only the macro's OWN definition changes —
# must re-key the node whose body came from that macro's expansion (a store
# MISS + recompute, proven via `pp why` and the journal), and reverting the
# definition must hit again (SPEC law 20). This is possible only because
# expansion happens BEFORE hash_expr ever sees the node's body (macro.ml is
# the one shared point both backends pass through): hash_expr operates on
# the EXPANDED form, so a macro-only edit is not invisible to the store the
# way it would be if the code hash were computed before/independent of
# expansion.
#
# Also pins the macro-in-node-body rule: a `defmacro` textually inside a
# `(node ...)` body is never specially recognized — only a TRUE top-level
# form registers a macro (macro.ml's documented decision) — so it reaches
# eval/compile as an ordinary application of the unbound symbol "defmacro",
# identically in both backends.
#
# Runs under an isolated HOME; both backends.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME FILE PATTERN present|absent
  local name="$1" file="$2" pat="$3" mode="$4"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else
    echo "FAIL $name: expected '$pat' $mode, got $hit"
    echo "--- $file ---"; cat "$file"; fail=1
  fi
}

# A build.pp-style program: the node's BODY is produced by EXPANDING a
# macro (`(build-step)`), never written out directly. v1 and v2 differ
# ONLY in the macro's own definition — the call site `(build-step)` is
# byte-identical in both files.
cat > "$TMP/v1.pp" <<'EOF'
defmacro build-step() {
  quote { do { perform log("COMPUTE"); 1 } } }
print(force(node { build-step() }))
EOF
cat > "$TMP/v2.pp" <<'EOF'
defmacro build-step() {
  quote { do { perform log("COMPUTE"); 2 } } }
print(force(node { build-step() }))
EOF

# The SAME rekey battery, authored in the OTHER surface (.ppl, sexpr) —
# same macro, same call site, same edit, proving the rekey property (SPEC
# law 20) is a property of the AST macro.ml expands, not of which reader
# produced it: every existing macro test passes authored in either
# surface.
cat > "$TMP/v1.ppl" <<'EOF'
(defmacro (build-step) '(do (perform log "COMPUTE") 1))
(print (force (node (build-step))))
EOF
cat > "$TMP/v2.ppl" <<'EOF'
(defmacro (build-step) '(do (perform log "COMPUTE") 2))
(print (force (node (build-step))))
EOF

rekey_battery() {  # EXT (".pp" or ".ppl") -> asserts, using $TMP/v1$EXT/v2$EXT
  local ext="$1"
  for flag in "" "--bytecode"; do
    if [ -z "$flag" ]; then tag="tw$ext"; else tag="vm$ext"; fi
    rm -rf "$TMP/.pp"

    "$PP" $flag "$TMP/v1$ext" > "$TMP/o1" 2>&1
    assert "$tag-v1-cold-miss-computes" "$TMP/o1" "COMPUTE" present
    assert "$tag-v1-cold-value"         "$TMP/o1" "^1$"     present

    "$PP" $flag "$TMP/v1$ext" > "$TMP/o1b" 2>&1
    assert "$tag-v1-rerun-hit-no-compute" "$TMP/o1b" "COMPUTE" absent
    assert "$tag-v1-rerun-value"          "$TMP/o1b" "^1$"     present

    "$PP" $flag why "$TMP/v1$ext" > "$TMP/why1" 2>&1
    assert "$tag-v1-why-reports-hit" "$TMP/why1" "\[why\].*hit" present

    # Same call site, EDITED macro definition: the node's expanded code hash
    # changes (SPEC law 20), so this MUST miss and recompute.
    "$PP" $flag "$TMP/v2$ext" > "$TMP/o2" 2>&1
    assert "$tag-v2-edit-miss-computes" "$TMP/o2" "COMPUTE" present
    assert "$tag-v2-edit-value"         "$TMP/o2" "^2$"     present

    "$PP" $flag why "$TMP/v2$ext" > "$TMP/why2" 2>&1
    assert "$tag-v2-why-reports-hit-after-recompute" "$TMP/why2" "\[why\].*hit" present

    # Revert to v1: the ORIGINAL key is still in the store, so this hits
    # again — no recompute.
    "$PP" $flag "$TMP/v1$ext" > "$TMP/o3" 2>&1
    assert "$tag-v1-revert-hit-no-compute" "$TMP/o3" "COMPUTE" absent
    assert "$tag-v1-revert-value"          "$TMP/o3" "^1$"     present
  done
}

rekey_battery ".pp"
rekey_battery ".ppl"
# NOTE: deliberately not also asserting the .pp and .ppl runs HIT the same
# store key as each other. A node's key includes ELocated (source path,
# line), per SPEC law 20, so v1.pp and v1.ppl, being different FILES, get
# different keys regardless of surface; that would be pinning file-path
# sensitivity, not surface-independence.

# --- macro-in-node-body: an ordinary unbound-symbol error, both backends ---
cat > "$TMP/innode.pp" <<'EOF'
print(force(node { defmacro m(x) { x } }))
EOF
"$PP" "$TMP/innode.pp" > "$TMP/inn-tw" 2>&1
assert "macro-in-node-tw-error" "$TMP/inn-tw" "unbound symbol: defmacro" present
"$PP" --bytecode "$TMP/innode.pp" > "$TMP/inn-vm" 2>&1
assert "macro-in-node-vm-error" "$TMP/inn-vm" "unbound symbol: defmacro" present
diff -u "$TMP/inn-tw" "$TMP/inn-vm" > "$TMP/inn-diff" 2>&1
if [ -s "$TMP/inn-diff" ]; then
  echo "FAIL macro-in-node-backends-identical"; cat "$TMP/inn-diff"; fail=1
else
  echo "ok   macro-in-node-backends-identical"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== DEFMACRO REKEY (LAW 20 / M3 exit 3) TEST PASSED ==="; fi
exit $fail
