#!/usr/bin/env bash
# Adversarial world for $secret (SPEC LAW 39 / M4 sealed cells).
# $secret reads under CapSecret and returns a VSealed value (redacted surface).
# Threats:
#   - escaping the secret grant via a symlink or `..` to a file outside it,
#   - the sealed bytes leaking to stdout as plaintext.
# Escapes must be DENIED (canonicalization before the CapSecret containment
# check, exactly like $file); a legitimate read must print the REDACTED form
# ("#<sealed>"), never the plaintext.
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
SB=$(mktemp -d); OUT=$(mktemp -d)
trap 'rm -rf "$SB" "$OUT"' EXIT

PLAINTEXT="TOPSECRET-PLAINTEXT-BYTES"
printf '%s\n' "$PLAINTEXT" > "$OUT/outside.txt"
printf '%s\n' "$PLAINTEXT" > "$SB/k.txt"
ln -s "$OUT/outside.txt" "$SB/link-out"
OUT_BASE=$(basename "$OUT")

fail=0

deny() {  # NAME  EXPR
  local name="$1" expr="$2"
  local out
  out=$("$PP" --grant "secret:$SB" -e "$expr" 2>&1 || true)
  if [ "$(printf '%s' "$out" | grep -c "$PLAINTEXT")" -gt 0 ]; then
    echo "FAIL $name: LEAKED plaintext of an out-of-scope secret"; echo "     $out"; fail=1
  elif [ "$(printf '%s' "$out" \
       | grep -ciE "permission denied|no read access|no read or write|symbolic links|error")" -gt 0 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: neither denied nor errored:"; echo "     $out"; fail=1
  fi
}

# Positive control: an in-scope secret read succeeds but is REDACTED — the
# plaintext must never appear even for a legitimately-granted read.
out=$("$PP" --grant "secret:$SB" -e "print(\$secret(\"$SB/k.txt\"))" 2>&1 || true)
if [ "$(printf '%s' "$out" | grep -c "$PLAINTEXT")" -gt 0 ]; then
  echo "FAIL redaction: plaintext printed for a granted secret"; echo "     $out"; fail=1
elif [ "$(printf '%s' "$out" | grep -c "sealed")" -eq 0 ]; then
  echo "FAIL redaction: expected a redacted #<sealed> value:"; echo "     $out"; fail=1
else
  echo "ok   redaction (granted read is #<sealed>, not plaintext)"
fi

deny symlink-escape "print(\$secret(\"$SB/link-out\"))"
deny dotdot-escape  "print(\$secret(\"$SB/../$OUT_BASE/outside.txt\"))"

exit $fail
