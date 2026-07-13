#!/bin/sh
# stdlib/string.pp adds string helpers over the string builtins.
export HOME=$(mktemp -d)
cd "$(dirname "$(dirname "$PP")")"

"$PP" /dev/stdin <<'PP'
(load "stdlib/string.pp")
(print (string-join ", " (list "a" "b" "c")))
(print (starts-with? "hello" "he"))
(print (ends-with? "hello" "lo"))
(print (lines "a
b
c"))
PP

rm -rf "$HOME"
