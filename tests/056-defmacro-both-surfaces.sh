#!/usr/bin/env bash
# tests/056 — M7 S5 exit criterion: "every existing macro test passes
# authored in either surface, differentially" (docs/M7-SYNTAX.md's S5
# stage). tests/041-defmacro.pp (braces, quote{}/quasiquote{}/unquote()/
# splice()) and tests/041-defmacro.ppl (sexpr, `'`/`` ` ``/`,`/`,@`) are the
# SAME test — same macros, same call sites, same expected values — one
# transliterated from the other. The differential suite (scripts/run-
# tests.sh's main loop) already proves each file agrees with ITSELF across
# backends; this script is the missing cell of the 2x2 (2 surfaces x 2
# backends): both files must ALSO agree with EACH OTHER, on both backends —
# proving quasiquote{}'s S5 ergonomics lowered to the exact same AST shapes
# the sexpr reader's quasiquote has always built (src/macro.ml,
# the expander, and hash_expr never changed).
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

BRACE=tests/041-defmacro.pp
SEXPR=tests/041-defmacro.ppl

for f in "$BRACE" "$SEXPR"; do
  if [ ! -f "$f" ]; then
    bad "056-fixture-present" "missing $f"
    echo "$fail"; exit 1
  fi
done

tw_brace=$("$PP"             "$BRACE" 2>&1)
vm_brace=$("$PP" --bytecode  "$BRACE" 2>&1)
tw_sexpr=$("$PP"             "$SEXPR" 2>&1)
vm_sexpr=$("$PP" --bytecode  "$SEXPR" 2>&1)

# Each file agrees with itself across backends (already covered by the main
# loop for the .pp; the .ppl isn't matched by that loop's `tests/[0-9]*.pp`
# glob, so it is only ever run here).
if [ "$tw_brace" = "$vm_brace" ]; then ok "056-brace-tw-eq-vm"
else bad "056-brace-tw-eq-vm" "tw: $tw_brace" "vm: $vm_brace"; fi

if [ "$tw_sexpr" = "$vm_sexpr" ]; then ok "056-sexpr-tw-eq-vm"
else bad "056-sexpr-tw-eq-vm" "tw: $tw_sexpr" "vm: $vm_sexpr"; fi

# The actual S5 exit criterion: braces and sexpr agree with EACH OTHER, on
# EACH backend.
if [ "$tw_brace" = "$tw_sexpr" ]; then ok "056-tw-brace-eq-sexpr"
else bad "056-tw-brace-eq-sexpr" "brace: $tw_brace" "sexpr: $tw_sexpr"; fi

if [ "$vm_brace" = "$vm_sexpr" ]; then ok "056-vm-brace-eq-sexpr"
else bad "056-vm-brace-eq-sexpr" "brace: $vm_brace" "sexpr: $vm_sexpr"; fi

# Pin the expected values too (not just cross-agreement) — a bug that
# corrupts BOTH surfaces identically would otherwise sail through the four
# checks above.
expected='"=== control-flow macro (unless), via quasiquote ==="
42
nil
""
"=== gensym: a macro'"'"'s own temp binding must not capture a ==="
"=== caller variable of the same name (M3 hygiene discipline) ==="
7
9
""
"=== a macro building a (node ...) form ==="
5
""
"=== nested macro use: one macro'"'"'s expansion calls another macro ==="
"hi"
"hi"
""
"=== macro-generated def ==="
15
""
"=== a macro built with list/quote (no quasiquote) ==="
42
""
"=== redefining a macro changes later expansions ==="
1
2
""
"=== EXPECTED: 42 nil / 7 9 / 5 / hi hi / 15 / 42 / 1 2 ==="'

if [ "$tw_brace" = "$expected" ]; then ok "056-brace-value-pin"
else bad "056-brace-value-pin" "expected: $expected" "got:      $tw_brace"; fi

if [ "$fail" -eq 0 ]; then
  echo "=== DEFMACRO BOTH-SURFACES (M7 S5) TEST PASSED ==="
fi
exit $fail
