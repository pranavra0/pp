#!/usr/bin/env bash
# Adversarial world for $secret (SPEC LAW 39 / M4 sealed cells).
# $secret reads under CapSecret and returns a VSealed value (redacted surface).
# Threats:
#   - escaping the secret grant via a symlink or `..` to a file outside it,
#   - the sealed bytes leaking to stdout as plaintext.
# Escapes must be DENIED (canonicalization before the CapSecret containment
# check, exactly like $file); a legitimate read must print the REDACTED form
# ("#<sealed>"), never the plaintext. Both backends must agree.
set -uo pipefail
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
  local name="$1" expr="$2" bad=0
  for bk in "" "--bytecode"; do
    local out
    out=$("$PP" $bk --grant "secret:$SB" -e "$expr" 2>&1 || true)
    if printf '%s' "$out" | grep -q "$PLAINTEXT"; then
      echo "FAIL $name${bk:+ ($bk)}: LEAKED plaintext of an out-of-scope secret"; echo "     $out"; bad=1
    elif printf '%s' "$out" \
         | grep -qiE "permission denied|no read access|no read or write|symbolic links|error"; then
      : # denied — defeated
    else
      echo "FAIL $name${bk:+ ($bk)}: neither denied nor errored:"; echo "     $out"; bad=1
    fi
  done
  if [ $bad -eq 0 ]; then echo "ok   $name"; else fail=1; fi
}

# Positive control: an in-scope secret read succeeds but is REDACTED — the
# plaintext must never appear even for a legitimately-granted read.
pc=0
for bk in "" "--bytecode"; do
  out=$("$PP" $bk --grant "secret:$SB" -e "print(\$secret(\"$SB/k.txt\"))" 2>&1 || true)
  if printf '%s' "$out" | grep -q "$PLAINTEXT"; then
    echo "FAIL redaction${bk:+ ($bk)}: plaintext printed for a granted secret"; echo "     $out"; pc=1
  elif ! printf '%s' "$out" | grep -q "sealed"; then
    echo "FAIL redaction${bk:+ ($bk)}: expected a redacted #<sealed> value:"; echo "     $out"; pc=1
  fi
done
if [ $pc -eq 0 ]; then echo "ok   redaction (granted read is #<sealed>, not plaintext)"; else fail=1; fi

deny symlink-escape "print(\$secret(\"$SB/link-out\"))"
deny dotdot-escape  "print(\$secret(\"$SB/../$OUT_BASE/outside.txt\"))"

exit $fail
