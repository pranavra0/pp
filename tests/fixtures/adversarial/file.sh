#!/usr/bin/env bash
# Adversarial world for $file (SPEC LAW 23 / DESIGN §2.1).
# $file lowers to slurp and records a file: cell. Threats that try to reach a
# file OUTSIDE the granted scope while LOOKING like an in-scope path:
#   - a symlink inside the sandbox pointing out of it,
#   - a `..` traversal,
#   - a self-referential symlink loop.
# Each must be DEFEATED: canonicalization (World_path.canonical — resolves
# symlinks and collapses `..`) runs BEFORE the containment check
# (Capabilities.path_grants → Paths.under), so the resolved path is judged, not
# its spelling. A loop cannot resolve, so it fails closed at the OS read. In no
# case does the outside file's contents reach stdout.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
SB=$(mktemp -d); OUT=$(mktemp -d)
trap 'rm -rf "$SB" "$OUT"' EXIT

SENTINEL="SECRET-OUTSIDE-THE-SANDBOX"
printf '%s\n' "$SENTINEL" > "$OUT/secret.txt"
printf 'inside-ok\n' > "$SB/ok.txt"
ln -s "$OUT/secret.txt" "$SB/link-out"       # symlink escaping the grant
ln -s "$SB/loop" "$SB/loop"                   # self-referential loop
OUT_BASE=$(basename "$OUT")

fail=0

# A read that must be DENIED and must never exfiltrate.
deny() {  # NAME  EXPR
  local name="$1" expr="$2"
  local out
  out=$("$PP" --grant "fs:$SB:ro" -e "$expr" 2>&1 || true)
  if printf '%s' "$out" | grep -q "$SENTINEL"; then
    echo "FAIL $name: EXFILTRATED the outside file"; echo "     $out"; fail=1
  elif printf '%s' "$out" \
       | grep -qiE "permission denied|no read access|no read or write|symbolic links|error"; then
    echo "ok   $name"
  else
    echo "FAIL $name: neither denied nor errored:"; echo "     $out"; fail=1
  fi
}

# Positive control: a genuine in-scope read still works, so the grant is not
# vacuously denying everything.
out=$("$PP" --grant "fs:$SB:ro" -e "print(\$file(\"$SB/ok.txt\"))" 2>&1 || true)
printf '%s' "$out" | grep -q "inside-ok" || { echo "FAIL positive-control: $out"; fail=1; }
echo "ok   positive-control"

deny symlink-escape "print(\$file(\"$SB/link-out\"))"
deny dotdot-escape  "print(\$file(\"$SB/../$OUT_BASE/secret.txt\"))"
deny symlink-loop   "print(\$file(\"$SB/loop\"))"

exit $fail
