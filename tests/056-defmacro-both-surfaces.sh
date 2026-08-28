#!/usr/bin/env bash
# tests/056 — every macro test must pass whether authored in either surface.
# tests/041-defmacro.pp (braces, quote{}/quasiquote{}/unquote()/splice()) and
# tests/041-defmacro.ppl (sexpr, `'`/`` ` ``/`,`/`,@`) are the SAME test —
# same macros, same call sites, same expected values — one transliterated
# from the other. This script verifies both files agree with EACH OTHER,
# proving the brace surface's quasiquote{} lowers to the exact same AST
# shapes the sexpr reader has always built (the shared macro expansion path in
# `lisp/runtime/language.lisp`, and the kernel identity functions).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
BRACE=tests/041-defmacro.pp
SEXPR=tests/041-defmacro.ppl

for f in "$BRACE" "$SEXPR"; do
  if [ ! -f "$f" ]; then
    bad "056-fixture-present" "missing $f"
    echo "$fail"; exit 1
  fi
done

got_brace=$("$PP" "$BRACE" 2>&1)
got_sexpr=$("$PP" "$SEXPR" 2>&1)

# The core property: braces and sexpr agree with EACH OTHER.
if [ "$got_brace" = "$got_sexpr" ]; then ok "056-brace-eq-sexpr"
else bad "056-brace-eq-sexpr" "brace: $got_brace" "sexpr: $got_sexpr"; fi

# Pin the expected values too (not just cross-agreement) — a bug that
# corrupts BOTH surfaces identically would otherwise sail through the check
# above.
expected='"=== control-flow macro (unless), via quasiquote ==="
42
nil
""
"=== gensym: a macro'"'"'s own temp binding must not capture a ==="
"=== caller-name hygiene ==="
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

if [ "$got_brace" = "$expected" ]; then ok "056-brace-value-pin"
else bad "056-brace-value-pin" "expected: $expected" "got:      $got_brace"; fi

if [ "$fail" -eq 0 ]; then
  echo "=== DEFMACRO BOTH-SURFACES TEST PASSED ==="
fi
exit $fail
