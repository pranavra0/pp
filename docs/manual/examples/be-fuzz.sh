#!/bin/sh
# The metamorphic fuzzer generates random programs, applies
# semantics-preserving transforms, and asserts the twin produces
# identical output. `--dump 0` prints the first generated program.
export HOME=$(mktemp -d)

echo '$ dune exec ./tools/fuzz.exe -- --grammar core --seed 0 --dump 0'
dune exec ./tools/fuzz.exe -- --grammar core --seed 0 --dump 0 2>/dev/null

rm -rf "$HOME"
