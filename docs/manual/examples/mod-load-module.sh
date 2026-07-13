#!/bin/sh
# Two ways to bring a file's definitions in. `load` MERGES a file into the
# current scope (its defs become directly visible). `load-module` loads the
# same file ISOLATED and returns its exports as a value, which you then
# `import` — so the file's own scope never leaks in. Hermetic throwaway HOME.
export HOME=$(mktemp -d)
cd "$HOME"

cat > mathlib.pp <<'PP'
def square(x) { x * x }
def cube(x) { x * square(x) }
PP

cat > use-load.pp <<'PP'
# load: mathlib's defs merge into this scope.
load("mathlib.pp")
print(square(9))
PP
echo '$ pp use-load.pp          # load merges definitions in'
"$PP" use-load.pp 2>&1

echo
cat > use-load-module.pp <<'PP'
# load-module: mathlib loads isolated; its exports come back as a value.
let (m = load-module("mathlib.pp")) {
  import(m)
  print(cube(3))
}
PP
echo '$ pp use-load-module.pp   # load-module returns exports to import'
"$PP" use-load-module.pp 2>&1

rm -rf "$HOME"
