#!/bin/sh
# stdlib/list.pp adds the higher-order list functions. It resolves relative to
# the repo root, so the script runs pp from there.
export HOME=$(mktemp -d)
cd "$(dirname "$(dirname "$PP")")"

"$PP" /dev/stdin <<'PP'
(load "stdlib/list.pp")
(print (range 1 6))
(print (foldl + 0 (range 1 6)))
(print (filter (fn (x) (> x 2)) (list 1 2 3 4)))
(print (take 2 (list 10 20 30 40)))
(print (drop 2 (list 10 20 30 40)))
(print (reverse (list 1 2 3)))
(print (length (list 1 2 3 4)))
(print (nth 1 (list 10 20 30)))
(print (append (list 1 2) (list 3 4)))
(print (member? 2 (list 1 2 3)))
PP

rm -rf "$HOME"
