#!/bin/sh
# stdlib/map.pp builds on the map builtins and on stdlib/list.pp, so load that
# first.
export HOME=$(mktemp -d)
cd "$(dirname "$(dirname "$PP")")"

"$PP" /dev/stdin <<'PP'
(load "stdlib/list.pp")
(load "stdlib/map.pp")
(def m (hash-map :a 1 :b 2))
(print (map-has? m :a))
(print (map-has? m :z))
(print (map-merge m (hash-map :b 9 :c 3)))
PP

rm -rf "$HOME"
