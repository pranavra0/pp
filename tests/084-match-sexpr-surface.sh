#!/usr/bin/env bash
# tests/084 — C4: sexpr surface for `match`. The sexpr reader now parses
# `(match scrutinee (pat [if guard] body) …)` — the exact grammar
# Printer_sexpr emits — so match-using files round-trip through `--to-sexpr`
# and rejoin the whole-tree fmt sweep (they were its last exclusion). Patterns
# are `_`, a literal, a bare symbol (variable), `(list p… [. rest])`, and
# `(tagged tag p…)`.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# A match file covering every pattern kind AND a guard.
cat > "$TMP/m.pp" <<'EOF'
def describe(r) {
  match r {
    [:ok, v] if v > 10 => "big ok"
    [:ok, v] => "small ok"
    (:err e) => e
    [x, y, ...rest] => "long list"
    [only] => "singleton"
    [] => "empty"
    42 => "the answer"
    _ => "other"
  }
}
print(describe([:ok, 50]))
print(describe([:ok, 3]))
print(describe([:err, "boom"]))
print(describe([1, 2, 3, 4]))
print(describe([9]))
print(describe([]))
print(describe(42))
print(describe("x"))
EOF

expected=$'"big ok"\n"small ok"\n"boom"\n"long list"\n"singleton"\n"empty"\n"the answer"\n"other"'

# (a) the brace file itself runs correctly (baseline).
got=$("$PP" "$TMP/m.pp" 2>&1)
if [ "$got" = "$expected" ]; then
  ok "brace-baseline"
else
  bad "brace-baseline" "got: $(printf '%q' "$got")"
fi

# (b) transpile to sexpr, and the SEXPR file runs identically
#     (the sexpr reader now understands match — the C4 change).
"$PP" fmt --to-sexpr "$TMP/m.pp" > "$TMP/m.ppl" 2>"$TMP/e1"
if [ ! -s "$TMP/m.ppl" ]; then
  bad "to-sexpr" "$(cat "$TMP/e1")"
else
  ok "to-sexpr"
fi
got=$("$PP" "$TMP/m.ppl" 2>&1)
if [ "$got" = "$expected" ]; then
  ok "sexpr-runs-identically"
else
  bad "sexpr-runs-identically" "got: $(printf '%q' "$got")"
fi

# (c) full round-trip braces → sexpr → braces preserves the LAW-20 hash (this
#     is the property that lets match files rejoin the tests/055 sweep).
"$PP" fmt --to-braces "$TMP/m.ppl" > "$TMP/m2.pp" 2>"$TMP/e2"
if "$PP" --compare-hash "$TMP/m.pp" "$TMP/m2.pp" >/dev/null 2>&1; then
  ok "roundtrip-hash-preserved"
else
  bad "roundtrip-hash-preserved" "$(cat "$TMP/e2")" \
      "$(diff "$TMP/m.pp" "$TMP/m2.pp" | head -20)"
fi

# (d) a hand-written sexpr `(match …)` (not printer-generated) parses and runs,
#     proving the reader path stands on its own — including a dotted-rest list
#     pattern and a guard.
cat > "$TMP/hand.ppl" <<'EOF'
(def (f xs)
  (match xs
    ((list a . rest) if (> a 0) "pos-head")
    ((list a . rest) "nonpos-head")
    (_ "not-a-list")))
(print (f (list 5 6 7)))
(print (f (list -1 2)))
(print (f 3))
EOF
got=$("$PP" "$TMP/hand.ppl" 2>&1)
handexp=$'"pos-head"\n"nonpos-head"\n"not-a-list"'
if [ "$got" = "$handexp" ]; then
  ok "hand-written-sexpr-match"
else
  bad "hand-written-sexpr-match" "got: $(printf '%q' "$got")"
fi

exit $fail
