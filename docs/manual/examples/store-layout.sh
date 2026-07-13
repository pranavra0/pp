#!/bin/sh
# The store has three content-addressed parts. A temp HOME keeps it throwaway.
export HOME=$(mktemp -d)
cd "$HOME"

cat > build.pp <<'PP'
(def artifact (node (blob (slurp "input.txt"))))
(print artifact)
PP
echo hello > input.txt

echo '$ pp build.pp --grant fs:$HOME:ro'
"$PP" build.pp --grant "fs:$HOME:ro"

echo
echo '$ ls ~/.pp/store'
ls "$HOME/.pp/store"

rm -rf "$HOME"
