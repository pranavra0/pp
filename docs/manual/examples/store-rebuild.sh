#!/bin/sh
# A cache hit is decided by re-checking what the node observed, not by a
# timestamp. `pp why` reports each node's fate. A temp HOME keeps the store
# throwaway; ROOT is the canonicalized HOME, stripped from output so the
# transcript is machine-independent (the cell ids are absolute paths).
export HOME=$(mktemp -d)
ROOT=$(cd "$HOME" && pwd -P)
cd "$HOME"

cat > build.pp <<'PP'
(def greeting (node (slurp "greeting.txt")))
(print greeting)
PP
echo hello > greeting.txt

echo '$ pp why build.pp --grant fs:$HOME:ro    # first build: a miss'
"$PP" why build.pp --grant "fs:$HOME:ro" 2>&1 | sed "s|$ROOT/||g"

echo
echo '$ pp why build.pp --grant fs:$HOME:ro    # input unchanged: a hit'
"$PP" why build.pp --grant "fs:$HOME:ro" 2>&1 | sed "s|$ROOT/||g"

echo
echo goodbye > greeting.txt
echo '$ pp why build.pp --grant fs:$HOME:ro    # input edited: re-run'
"$PP" why build.pp --grant "fs:$HOME:ro" 2>&1 | sed "s|$ROOT/||g"

rm -rf "$HOME"
