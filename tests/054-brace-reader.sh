#!/usr/bin/env bash
# tests/054 — the brace reader (SPEC Appendix B): a location-preserving
# sexpr<->brace printer, tested across both readers.
#
#   (a) a nontrivial .pp program (infix precedence, pipeline, cell literals,
#       and/or, map/vector literals, do/let/let*/if-else, node + needs,
#       with-handler/with-config/config, defmacro, quote{}/quasiquote{}/
#       unquote/splice, `;` separators, `#` comments) runs correctly;
#   (b) a .ppl loads a .pp and vice versa; a pinned
#       island whose tree ships entry.pp imports from a .ppl program, and a
#       .pp program imports an island via the string-URI spelling;
#   (c) assert parity (SPEC law 29): the SAME assert at the same line
#       produces the same desugared message in both surfaces (condition
#       rendered in s-expression notation), modulo only the file name;
#   (d) `pp fmt --to-braces` on a real sexpr test file produces a .pp whose
#       output matches the .pp original's;
#   (e) `pp --check-roundtrip` (AST + hash equality through the printer and
#       the second reader, SPEC law 20) holds for every .pp in the tree;
#   (f) the metamorphic fuzzer's round-trip gate passes on a few hundred
#       full-grammar programs (2 readers).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
FUZZ=${FUZZ:-tools/fuzz.exe}
if [ ! -x "$FUZZ" ] && [ -x "_build/default/tools/fuzz.exe" ]; then
  FUZZ="_build/default/tools/fuzz.exe"
fi
case "$FUZZ" in /*) : ;; *) FUZZ="$PWD/$FUZZ" ;; esac
ROOT="$PWD"
STDLIB="$ROOT/stdlib/list.pp"

# ---- (a) the nontrivial .pp program ----
# covers: comments, ';' separators, infix precedence, pipeline, infix
# and/or (right-assoc desugar), operator-as-value, n-ary call form,
# vector/map literals, quote{}/quasiquote{}/unquote/splice, type annotations
# (SPEC law 32), node+needs, reconcile, do, let*/let groups with newline
# continuation, with-handler/with-config/config, defmacro, kebab identifiers
# vs the whitespace rule, if/else-if/else, module/import.
mkdir -p "$TMP/a"
cat > "$TMP/a/main.pp" <<EOF
load("$STDLIB")
let x = 2 + 3 * 4; print(x)
x |> print
1 + 2 |> print
print(1 < 2 and 2 < 3)
print(false or 7)
print(foldl(+, 0, list(1, 2, 3)))
print(+(1, 2, 3))
print([1, 2 * 2, 3])
print({:a -> 1, "b" -> [2]})
print(quote { string-index })
print(quasiquote { f(unquote(1 + 1), 3) })
print(quasiquote { g(splice(list(1, 2)), 9) })
def add-two(n: int): int { n + 2 }
print(add-two(5))
node build(v) needs current-capabilities() { v + 1 }
print(force(build(1)))
let m = reconcile { "k" -> 1 }
print(m)
do { let y = 1; print(y + 10) }
let* (a = 1, a = a + 1) { print(a) }
let (p = 1,
     q = 2) { print(p + q) }
with-handler(log! = fn(msg) { 99 }) { print(log!("zzz")) }
with-config({:k -> 5}) { print(\$config(:k, 0)) }
defmacro twice(e) { list(quote { + }, e, e) }
print(twice(21))
def a-b(z) { z - 1 }        # whitespace rule: z - 1 subtracts; a-b is a name
print(a-b(3))
if 1 < 2 { print("lt") } else if 1 = 2 { print("eq") } else { print("ge") }
import(module { export helper; def helper(n) { n * 5 } })
print(helper(10))
EOF
expected='14
14
3
true
7
6
6
(1 4 3)
{:a 1, "b" (2)}
string-index
(f 2 3)
(g 1 2 9)
7
2
{"k" 1}
11
2
3
99
5
42
2
"lt"
50'
# fresh HOME so node-cache hit/miss cannot skew stdout
got=$(HOME="$TMP/h" "$PP" "$TMP/a/main.pp" 2>"$TMP/a/err")
if [ "$got" = "$expected" ]; then ok "pp-program"
else bad "pp-program" "expected: $(printf '%q' "$expected")" "got:      $(printf '%q' "$got")" "stderr: $(cat "$TMP/a/err")"; fi

# ---- (b) cross-surface loading + islands ----
mkdir -p "$TMP/b"
cat > "$TMP/b/lib.pp" <<'EOF'
def lib-fn(n) { n * 10 }
EOF
cat > "$TMP/b/use.ppl" <<'EOF'
(load "lib.pp")
(print (lib-fn 4))
EOF
cat > "$TMP/b/lib2.ppl" <<'EOF'
(def (lib2-fn n) (* n 100))
EOF
cat > "$TMP/b/use2.pp" <<'EOF'
load("lib2.ppl")
print(lib2-fn(4))
EOF

( cd "$TMP/b" &&
  [ "$("$PP" use.ppl 2>&1)" = "40" ] ) \
  && ok "ppl-loads-pp" || bad "ppl-loads-pp" "$(cd "$TMP/b" && "$PP" use.ppl 2>&1)"
( cd "$TMP/b" &&
  [ "$("$PP" use2.pp 2>&1)" = "400" ] ) \
  && ok "pp-loads-ppl" || bad "pp-loads-ppl" "$(cd "$TMP/b" && "$PP" use2.pp 2>&1)"

mkdir -p "$TMP/b/isl"
cat > "$TMP/b/isl/entry.pp" <<'EOF'
let isl-x = 41
def isl-add(n) { n + isl-x }
EOF
cat > "$TMP/b/useisl.ppl" <<EOF
(import (island file:$TMP/b/isl))
(print (isl-add 1))
EOF
if "$PP" --update "$TMP/b/useisl.ppl" >/dev/null 2>&1 \
   && [ "$("$PP" "$TMP/b/useisl.ppl" 2>&1)" = "42" ]; then
  ok "pp-island-from-ppl"
else
  bad "pp-island-from-ppl" "$("$PP" "$TMP/b/useisl.ppl" 2>&1)"
fi
PIN=$(sed -n 's/.*"\([0-9a-f]\{64\}\)".*/\1/p' "$TMP/b/useisl.ppl" | head -1)
cat > "$TMP/b/useisl2.pp" <<EOF
import(island("file:$TMP/b/isl", "$PIN"))
print(isl-add(9))
EOF
if [ -n "$PIN" ] && [ "$("$PP" "$TMP/b/useisl2.pp" 2>&1)" = "50" ]; then
  ok "island-string-uri-from-pp"
else
  bad "island-string-uri-from-pp" "pin=$PIN" "$("$PP" "$TMP/b/useisl2.pp" 2>&1)"
fi

# ---- (b, continued) both cross-surface island directions with the
# LITERAL .pp/.ppl extensions: a .ppl island loads from a .pp program
# and a .pp island loads from a .ppl program.
mkdir -p "$TMP/b/isl2"
cat > "$TMP/b/isl2/entry.ppl" <<'EOF'
(def isl2-x 41)
(def (isl2-add n) (+ n isl2-x))
EOF
cat > "$TMP/b/useisl3.pp" <<EOF
import(island("file:$TMP/b/isl2"))
print(isl2-add(1))
EOF
if "$PP" --update "$TMP/b/useisl3.pp" >/dev/null 2>&1 \
   && [ "$("$PP" "$TMP/b/useisl3.pp" 2>&1)" = "42" ]; then
  ok "ppl-island-from-pp"
else
  bad "ppl-island-from-pp" "$("$PP" "$TMP/b/useisl3.pp" 2>&1)"
fi

mkdir -p "$TMP/b/isl3"
cat > "$TMP/b/isl3/entry.pp" <<'EOF'
let isl3-x = 41
def isl3-add(n) { n + isl3-x }
EOF
cat > "$TMP/b/useisl4.ppl" <<EOF
(import (island file:$TMP/b/isl3))
(print (isl3-add 2))
EOF
if "$PP" --update "$TMP/b/useisl4.ppl" >/dev/null 2>&1 \
   && [ "$("$PP" "$TMP/b/useisl4.ppl" 2>&1)" = "43" ]; then
  ok "pp-island-from-ppl"
else
  bad "pp-island-from-ppl" "$("$PP" "$TMP/b/useisl4.ppl" 2>&1)"
fi

# ---- (c) assert parity: same message text (condition rendered as sexpr
#      data, `at file:line` suffix), modulo only the file name ----
mkdir -p "$TMP/c"
printf '(print "start")\n(assert (< 2 1))\n' > "$TMP/c/t.ppl"
printf 'print("start")\nassert(2 < 1)\n' > "$TMP/c/t.pp"
err_pp=$("$PP" "$TMP/c/t.ppl" 2>&1 >/dev/null | sed 's/t\.ppl/t.pp/')
err_roundtrip=$("$PP" "$TMP/c/t.pp" 2>&1 >/dev/null | sed 's/t\.pp/t.pp/')
if [ "$err_pp" = "$err_roundtrip" ] && printf '%s' "$err_pp" | grep -q 'assertion failed: (< 2 1) at .*t\.pp:2'; then
  ok "assert-desugar-parity"
else
  bad "assert-desugar-parity" "ppl: $err_pp" "pp: $err_roundtrip"
fi
# custom-message form
printf '(assert (< 2 1) "boom")\n' > "$TMP/c/m.ppl"
printf 'assert(2 < 1, "boom")\n' > "$TMP/c/m.pp"
err_pp=$("$PP" "$TMP/c/m.ppl" 2>&1 | sed 's/m\.ppl/m.pp/')
err_roundtrip=$("$PP" "$TMP/c/m.pp" 2>&1 | sed 's/m\.pp/m.pp/')
if [ "$err_pp" = "$err_roundtrip" ] && printf '%s' "$err_pp" | grep -q 'boom at .*m\.pp:1'; then
  ok "assert-message-parity"
else
  bad "assert-message-parity" "ppl: $err_pp" "pp: $err_roundtrip"
fi

# ---- (d) to-braces on a real file: same output ----
# The tree is brace-surface; derive the sexpr (.ppl) form first, then emit
# braces from IT — the emitted program must still behave correctly.
"$PP" fmt --to-sexpr "$ROOT/tests/007-phase0-laws.pp" > "$TMP/007.ppl" 2>"$TMP/emit.err" \
  || bad "fmt-to-sexpr-007" "$(cat "$TMP/emit.err")"
"$PP" fmt --to-braces "$TMP/007.ppl" > "$TMP/007.pp" 2>"$TMP/emit.err"
if [ $? -ne 0 ]; then bad "to-braces-007" "$(cat "$TMP/emit.err")"; fi
o_pp=$(HOME="$TMP/h-007-pp" "$PP" "$ROOT/tests/007-phase0-laws.pp" 2>&1)
o_roundtrip=$(HOME="$TMP/h-007-roundtrip" "$PP" "$TMP/007.pp" 2>&1)
if [ "$o_pp" = "$o_roundtrip" ] && printf '%s' "$o_roundtrip" | grep -q 'ALL TESTS PASSED'; then
  ok "to-braces-007-diff"
else
  bad "to-braces-007-diff" "outputs differ:" "$(diff <(printf '%s' "$o_pp") <(printf '%s' "$o_roundtrip") | head -6)"
fi

# ---- (e) round-trip (AST + hash equality, SPEC law 20) over the whole tree ----
# The tree is brace-surface; --check-roundtrip takes sexpr input (it
# round-trips sexpr -> braces -> re-read), so derive each file's .ppl form
# first — the property gated is unchanged: every tree file's AST survives
# the printer/second-reader round trip with hash equality.
rt_fail=0
mkdir -p "$TMP/rt"
for f in "$ROOT"/tests/[0-9]*.pp \
         "$ROOT"/tests/mutate-cproject.pp "$ROOT"/stdlib/*.pp \
         "$ROOT"/build.pp "$ROOT"/demo/volatile-deploy.pp "$ROOT"/examples/*.pp; do
  [ -f "$f" ] || continue
  if ! "$PP" fmt --to-sexpr "$f" > "$TMP/rt/tree.ppl" 2>"$TMP/rt.err"; then
    bad "roundtrip-tree-to-sexpr ($f)" "$(tail -1 "$TMP/rt.err")"
    rt_fail=1; continue
  fi
  if ! "$PP" --check-roundtrip "$TMP/rt/tree.ppl" >/dev/null 2>"$TMP/rt.err"; then
    bad "roundtrip-tree ($f)" "$(tail -1 "$TMP/rt.err")"
    rt_fail=1
  fi
done
[ "$rt_fail" = 0 ] && ok "roundtrip-whole-tree"

# ---- (f) the fuzz gate: a few hundred full-grammar programs through
#      2 readers produce one shared AST ----
if [ ! -x "$FUZZ" ]; then
  bad "fuzz-roundtrip-gate" "fuzzer binary not found at $FUZZ"
else
  if ( cd "$ROOT" && "$FUZZ" --grammar full --count 300 --pp "$PP" \
         --stdlib "$STDLIB" --out "$TMP/fuzz-failures" > "$TMP/fuzz.log" 2>&1 ); then
    if grep -q 'roundtrip  300 checked, 0 failed' "$TMP/fuzz.log"; then
      ok "fuzz-roundtrip-gate (300 full-grammar programs)"
    else
      bad "fuzz-roundtrip-gate" "roundtrip summary line missing:" "$(tail -8 "$TMP/fuzz.log")"
    fi
  else
    bad "fuzz-roundtrip-gate" "$(tail -20 "$TMP/fuzz.log")"
  fi
fi

if [ "$fail" = 0 ]; then
  echo "=== 054 BRACE READER: ALL PASS ==="
  exit 0
else
  exit 1
fi
