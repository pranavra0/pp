#!/usr/bin/env bash
# Adversarial world for $glob (SPEC LAW 23 / DESIGN §2.1).
# $glob lowers to (perform tree-observe path) and records a tree: cell. A tree
# observation is fs-read-gated on the ROOT, so the same escapes as $file must be
# defeated: a `..` traversal to an ungranted parent, and a symlink whose target
# is outside the grant. The observation must be denied (never returns a listing
# of an out-of-scope directory). Both backends must agree.
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
  local name="$1" expr="$2" bad=0
  for bk in "" "--bytecode"; do
    local out
    out=$("$PP" $bk --grant "fs:$SB:ro" -e "$expr" 2>&1 || true)
    if printf '%s' "$out" | grep -q "OUTSIDE-ENTRY"; then
      echo "FAIL $name${bk:+ ($bk)}: LISTED an out-of-scope directory"; echo "     $out"; bad=1
    elif printf '%s' "$out" \
         | grep -qiE "permission denied|no read access|no read or write|error"; then
      : # denied — defeated
    else
      echo "FAIL $name${bk:+ ($bk)}: neither denied nor errored:"; echo "     $out"; bad=1
    fi
  done
  if [ $bad -eq 0 ]; then echo "ok   $name"; else fail=1; fi
}

# Positive control: an in-scope tree observation works.
pc=0
for bk in "" "--bytecode"; do
  out=$("$PP" $bk --grant "fs:$SB:ro" -e "print(\$glob(\"$SB/sub\"))" 2>&1 || true)
  printf '%s' "$out" | grep -q "inside.txt" || { echo "FAIL positive-control${bk:+ ($bk)}: $out"; pc=1; }
done
if [ $pc -eq 0 ]; then echo "ok   positive-control"; else fail=1; fi

deny dotdot-escape  "print(\$glob(\"$SB/../$OUT_BASE\"))"
deny symlink-escape "print(\$glob(\"$SB/link-dir\"))"

exit $fail
