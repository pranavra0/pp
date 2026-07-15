#!/usr/bin/env bash
# tests/060 — quasiquote/list parity.
#
# In the brace surface, `[ ... ]` is the list literal: ordinary code lowers
# it to a cons-chain list value. Inside `quasiquote { }` the SAME
# bracket syntax must build the SAME value — not a vector. Before this fix
# the quasiquote path built a `(vector ...)`, so a macro template `[a, b]`
# produced a different value (a vector) than the code `[a, b]` it stands in
# for (a list). That divergence is a correctness bug: a template and the
# equivalent literal must be interchangeable.
#
# This pins value-parity between the template result and the literal, on
# both backends (differential), plus the empty and splice cases.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

# The value a quasiquote bracket template builds must equal the value the
# equivalent ordinary bracket code builds, and must be a list (pair?), never
# a vector.
cat > "$TMP/parity.pp" <<'EOF'
let a = 1
let b = 2
let tmpl = quasiquote { [unquote(a), unquote(b)] }
let code = [a, b]
print(tmpl = code)
print(pair?(tmpl))
print(vector?(tmpl))
print(quasiquote { [] } = [])
let xs = [10, 20]
print(quasiquote { [0, splice(xs), 30] })
EOF
expected=$'true\ntrue\nfalse\ntrue\n(0 10 20 30)'
got_tw=$("$PP" "$TMP/parity.pp" 2>&1)
got_bc=$("$PP" --bytecode "$TMP/parity.pp" 2>&1)
if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
  ok "qq-bracket-builds-list-both-backends"
else
  bad "qq-bracket-builds-list-both-backends" \
      "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")"
fi

# A quasiquoted bracket builds a DATA list of its (quasiquoted) elements —
# exactly as sexpr `` `(a b) `` does — so as generated CODE it reads as an
# application `(a b)`, not a list constructor. This is the same convention
# on both surfaces: to have a macro emit list-BUILDING code, quasiquote the
# call `list(...)`. Pin that the resulting list equals the literal, both
# backends. (This documents that the fix aligned qq brackets with the list
# literal's VALUE, not that qq brackets became a codegen shortcut.)
cat > "$TMP/macro.pp" <<'EOF'
defmacro mk-list(x, y) { quasiquote { list(unquote(x), unquote(y)) } }
print(mk-list(7, 8))
print(mk-list(7, 8) = [7, 8])
EOF
expected=$'(7 8)\ntrue'
got_tw=$("$PP" "$TMP/macro.pp" 2>&1)
got_bc=$("$PP" --bytecode "$TMP/macro.pp" 2>&1)
if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
  ok "qq-list-call-macro-generates-list"
else
  bad "qq-list-call-macro-generates-list" \
      "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")"
fi

exit $fail
