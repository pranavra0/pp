#!/usr/bin/env bash
# Adversarial world for $glob (SPEC LAW 23 / DESIGN §2.1).
# $glob lowers to (perform tree-observe path) and records a tree: cell. A tree
# observation is fs-read-gated on the ROOT, so the same escapes as $file must be
# defeated: a `..` traversal to an ungranted parent, and a symlink whose target
# is outside the grant. The observation must be denied (never returns a listing
# of an out-of-scope directory).
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
SB=$(mktemp -d); OUT=$(mktemp -d)
trap 'rm -rf "$SB" "$OUT"' EXIT

# The out-of-scope tree carries a file whose NAME would appear in a listing.
printf 'x\n' > "$OUT/OUTSIDE-ENTRY.txt"
mkdir -p "$SB/sub"; printf 'x\n' > "$SB/sub/inside.txt"
ln -s "$OUT" "$SB/link-dir"                   # symlink to an out-of-scope dir
OUT_BASE=$(basename "$OUT")

fail=0

deny() {  # NAME  EXPR
  local name="$1" expr="$2"
  local out
  out=$("$PP" --grant "fs:$SB:ro" -e "$expr" 2>&1 || true)
  if [ "$(printf '%s' "$out" | grep -c "OUTSIDE-ENTRY")" -gt 0 ]; then
    echo "FAIL $name: LISTED an out-of-scope directory"; echo "     $out"; fail=1
  elif [ "$(printf '%s' "$out" \
       | grep -ciE "permission denied|no read access|no read or write|error")" -gt 0 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: neither denied nor errored:"; echo "     $out"; fail=1
  fi
}
# Positive control: an in-scope tree observation works.
out=$("$PP" --grant "fs:$SB:ro" -e "print(\$glob(\"$SB/sub\"))" 2>&1 || true)
[ "$(printf '%s' "$out" | grep -c "inside.txt")" -gt 0 ] || { echo "FAIL positive-control: $out"; fail=1; }
echo "ok   positive-control"

deny dotdot-escape  "print(\$glob(\"$SB/../$OUT_BASE\"))"
deny symlink-escape "print(\$glob(\"$SB/link-dir\"))"

exit $fail
