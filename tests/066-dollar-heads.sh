#!/usr/bin/env bash
# tests/066 — observation `$KIND` heads are table-driven (Surface_tables)
# and parse arbitrary expression arguments.
#
# `$file`/`$env`/`$glob`/`$secret`/`$probe` accepted a STRING LITERAL only;
# real code computes paths/names. All heads now parse an ordinary expression
# list, so a computed name/default works — on both backends.
#
# The SAME table drives the normal reader and the quasiquote reader, so a
# `$head(...)` inside a quasiquote template builds a value equal to what the
# bare form lowers to.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_both() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP"            "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" \
        "expected: $(printf '%q' "$expected")" \
        "tw:       $(printf '%q' "$got_tw")" \
        "bc:       $(printf '%q' "$got_bc")"
  fi
}

export A6_VAR="present"

# (a) $env with a COMPUTED name expression (not a string literal).
cat > "$TMP/name.pp" <<'EOF'
def mk(s) { string-append("A6_", s) }
print($env(mk("VAR")))
EOF
run_both "env-computed-name" "$TMP/name.pp" '"present"'

# (b) $env with a computed DEFAULT expression, variable unset.
cat > "$TMP/def.pp" <<'EOF'
print($env("A6_MISSING", string-append("de", "fault")))
EOF
run_both "env-computed-default" "$TMP/def.pp" '"default"'

# (c) Arity is enforced from the table (env takes 1 or 2 args).
cat > "$TMP/arity.pp" <<'EOF'
print($env("A", "B", "C"))
EOF
got=$("$PP" "$TMP/arity.pp" 2>&1 || true)
if echo "$got" | grep -q '\$env expects'; then
  ok "env-arity-error-from-table"
else
  bad "env-arity-error-from-table" "got: $(printf '%q' "$got")"
fi

# (d) `$` is reserved for observation heads: an unknown $head is a parse error
#     that lists the known heads (from the table, so it can't drift).
cat > "$TMP/unk.pp" <<'EOF'
print($nope)
EOF
got=$("$PP" "$TMP/unk.pp" 2>&1 || true)
if echo "$got" | grep -q 'unknown observation head \$nope' \
   && echo "$got" | grep -q '\$file' && echo "$got" | grep -q '\$env'; then
  ok "unknown-head-errors-listing-known-heads"
else
  bad "unknown-head-errors-listing-known-heads" "got: $(printf '%q' "$got")"
fi

# (e) Quasiquote parity: a $env template with an unquoted hole builds the same
#     value the bare form lowers to — including the with-default If shape.
cat > "$TMP/qq.pp" <<'EOF'
defmacro mk(n) { quasiquote { $env(unquote(n)) } }
defmacro mkd(n, d) { quasiquote { $env(unquote(n), unquote(d)) } }
print(mk("A6_VAR") = $env("A6_VAR"))
print(mkd("A6_MISSING", "fb") = $env("A6_MISSING", "fb"))
print(mk("A6_VAR"))
EOF
run_both "qq-env-head-parity" "$TMP/qq.pp" $'true\ntrue\n"present"'

exit $fail
