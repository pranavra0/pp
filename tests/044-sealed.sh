#!/usr/bin/env bash
# pins: LAW-39
# Sealed cells: a confidential read is a distinct value kind, banned at the
# node boundary in both directions (SPEC law 39).
#
# `--grant secret:<path>` mints CapSecret. A read covered by CapSecret and
# NOT by CapFilesystem returns VSealed instead of VString: print redacts
# ("#<sealed>"), the bytes pin in-memory only (Runtime.sealed_pins, NEVER
# store_blob/the CAS), and the node boundary bans VSealed both directions
# exactly like VCapability. `(unseal v)` is the one explicit way out to
# VString — a Vault/SOPS-style boundary, not dataflow tainting: unsealing
# INSIDE a node makes the result ordinary data again, by design (a
# documented residual), so this suite's "never in store" checks are built
# around programs that never unseal inside a node.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME PATTERN present|absent  [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  local got
  if grep -qE "$pat" "$file"; then got=present; else got=absent; fi
  if [ "$got" = "$mode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$pat' $mode in $file, got $got"
    echo "--- output ---"; cat "$file"; fail=1
  fi
}

mkdir -p "$TMP/secret"
printf 'SECRETDATA\n' > "$TMP/secret/data.txt"
SECRET="$TMP/secret/data.txt"

# =====================================================================
# (1) sealed read redacts on print; unseal round-trips
# =====================================================================
cat > "$TMP/print-sealed.pp" <<EOF
print(slurp("$SECRET"))
EOF
cat > "$TMP/print-unsealed.pp" <<EOF
print(unseal(slurp("$SECRET")))
EOF
rm -rf "$TMP/.pp"
"$PP" --grant "secret:$TMP/secret" "$TMP/print-sealed.pp" > "$TMP/out" 2>&1
assert "sealed-print-redacted"     "#<sealed>"  present
assert "sealed-print-no-leak"      "SECRETDATA" absent
rm -rf "$TMP/.pp"
"$PP" --grant "secret:$TMP/secret" "$TMP/print-unsealed.pp" > "$TMP/out" 2>&1
assert "unseal-round-trips"        "SECRETDATA" present

# =====================================================================
# (2) secret bytes NEVER under ~/.pp/store (recursive grep, whole store —
#     blobs/ included, since a sealed read must NEVER call store_blob):
#     (a) a program that only reads (never unseals) the secret;
#     (b) a program that unseals, but at SCRIPT TIER only (never inside a
#         node) — keeping the plaintext out of anything the store touches.
# =====================================================================
rm -rf "$TMP/.pp"
cat > "$TMP/read-only.pp" <<EOF
force(node {
  slurp("$SECRET")
  "read-but-not-returned"
})
EOF
"$PP" --grant "secret:$TMP/secret" "$TMP/read-only.pp" > "$TMP/out" 2>&1
cat > "$TMP/unseal-script-tier.pp" <<EOF
print(string-length(unseal(slurp("$SECRET"))))
EOF
"$PP" --grant "secret:$TMP/secret" "$TMP/unseal-script-tier.pp" >> "$TMP/out" 2>&1
if grep -rq "SECRETDATA" "$TMP/.pp/store" 2>/dev/null; then
  echo "FAIL sealed-bytes-never-in-store: SECRETDATA found under ~/.pp/store"
  fail=1
else
  echo "ok   sealed-bytes-never-in-store"
fi

# =====================================================================
# (3) node boundary ban: free-var side and result side, both directions
# =====================================================================
cat > "$TMP/ban-freevar.pp" <<EOF
let s = slurp("$SECRET")
force(node { s })
EOF
cat > "$TMP/ban-result.pp" <<EOF
force(node { slurp("$SECRET") })
EOF

for case_name in ban-freevar ban-result; do
  rm -rf "$TMP/.pp"
  "$PP" --grant "secret:$TMP/secret" "$TMP/$case_name.pp" > "$TMP/$case_name.err" 2>&1
  assert "$case_name-names-sealed" "may not (be or contain a sealed value|return a sealed value)" present "$TMP/$case_name.err"
done

# =====================================================================
# (4) rotation invalidates EXACTLY the observing node.
# =====================================================================
rm -rf "$TMP/.pp"
mkdir -p "$TMP/rot"
printf 'V1\n' > "$TMP/rot/secret.txt"
cat > "$TMP/rotate.pp" <<EOF
perform log(force(node { perform log("COMPUTE-A"); slurp("$TMP/rot/secret.txt"); "done-a" }))
perform log(force(node {
  perform log("COMPUTE-B")
  "done-b"
}))
EOF
run_rotate() { rm -f "$TMP/out"; "$PP" --grant "secret:$TMP/rot" "$TMP/rotate.pp" > "$TMP/out" 2>&1; }

run_rotate
assert "rotate-run1-cold-a" "COMPUTE-A" present
assert "rotate-run1-cold-b" "COMPUTE-B" present

run_rotate
assert "rotate-run2-unchanged-a-hit" "COMPUTE-A" absent
assert "rotate-run2-unchanged-b-hit" "COMPUTE-B" absent

printf 'V2\n' > "$TMP/rot/secret.txt"
run_rotate
assert "rotate-run3-rotated-a-recomputes" "COMPUTE-A" present
assert "rotate-run3-rotated-b-still-hit"  "COMPUTE-B" absent

# =====================================================================
# (5) a caller without the secret grant can't hit a node whose closure
#     read sealed data (SPEC law 23b): populate the store under a grant,
#     then re-run the SAME program with NO grant at all — the cached trace
#     must not be servable, and the secret must not leak.
# =====================================================================
rm -rf "$TMP/.pp"
cat > "$TMP/narrow.pp" <<EOF
perform log(force(node { unseal(slurp("$SECRET")) }))
EOF
"$PP" --grant "secret:$TMP/secret" "$TMP/narrow.pp" > "$TMP/out" 2>&1
assert "narrow-populate-succeeds" "SECRETDATA" present
"$PP" "$TMP/narrow.pp" > "$TMP/out" 2>&1
assert "narrow-caller-no-leak"   "SECRETDATA" absent
assert "narrow-caller-denied"    "(apability|permission denied)"  present

# =====================================================================
# (6) both grants (secret AND fs) → ordinary fs behavior wins.
# =====================================================================
rm -rf "$TMP/.pp"
cat > "$TMP/both-grants.pp" <<EOF
print(slurp("$SECRET"))
EOF
"$PP" --grant "secret:$TMP/secret" --grant "fs:$TMP/secret:ro" "$TMP/both-grants.pp" > "$TMP/out" 2>&1
assert "both-grants-plain-fs"       "SECRETDATA" present
assert "both-grants-not-redacted"   "#<sealed>"  absent

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== SEALED CELLS (M4) TEST PASSED ==="; fi
exit $fail
