#!/usr/bin/env bash
# $stat must authorize the canonical path before revealing its kind.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
SB=$(mktemp -d); OUT=$(mktemp -d)
trap 'rm -rf "$SB" "$OUT"' EXIT

printf 'inside\n' > "$SB/inside.txt"
printf 'outside\n' > "$OUT/outside.txt"
ln -s "$OUT/outside.txt" "$SB/link-out"
OUT_BASE=$(basename "$OUT")
fail=0

deny() {
  local name="$1" path="$2" out
  out=$("$PP" --grant "fs:$SB:ro" -e "print(\$stat(\"$path\"))" 2>&1 || true)
  if printf '%s' "$out" | grep -q ':file'; then
    echo "FAIL $name: revealed an out-of-scope path kind"; fail=1
  elif printf '%s' "$out" | grep -qiE 'not granted|permission denied|error'; then
    echo "ok   $name"
  else
    echo "FAIL $name: neither denied nor errored: $out"; fail=1
  fi
}

out=$("$PP" --grant "fs:$SB:ro" -e "print(\$stat(\"$SB/inside.txt\"))" 2>&1 || true)
if printf '%s\n' "$out" | grep -qx ':file'; then echo "ok   positive-control"
else echo "FAIL positive-control: $out"; fail=1; fi

deny symlink-escape "$SB/link-out"
deny dotdot-escape "$SB/../$OUT_BASE/outside.txt"
exit $fail
