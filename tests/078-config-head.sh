#!/usr/bin/env bash
# tests/078 — $config joins the observation family.
#
# $config(key[, default]) reads a scoped config value installed by an enclosing
# `with { config: … }` extent (SPEC law 33), recording a config: trace cell —
# the $ family now covers every traced read kind. It lowers to the same
# EConfig node as the bare `config(key)` form, and templates inside
# quasiquote{} the same way every other $-form does (via the Surface_tables
# `Config` tmpl node).
#
# Differential: the tree-walker and the bytecode VM must agree byte for byte.
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
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "tw:       $(printf '%q' "$got_tw")" "bc:       $(printf '%q' "$got_bc")"
  fi
}

# (a) read a key set by the enclosing config extent.
cat > "$TMP/read.pp" <<'EOF'
with { config: { :cc -> "clang", :opt -> 2 } } {
  print($config("cc"))
  print($config("opt"))
}
EOF
run_both "config-read" "$TMP/read.pp" $'"clang"\n2'

# (b) default is used when the key is unset.
cat > "$TMP/default.pp" <<'EOF'
with { config: { :cc -> "clang" } } {
  print($config("missing", "fallback"))
}
EOF
run_both "config-default" "$TMP/default.pp" '"fallback"'

# (c) computed key expression: heads take expressions, not just literals.
cat > "$TMP/computed.pp" <<'EOF'
with { config: { :cflags -> "-O2" } } {
  print($config(string-append("cf", "lags")))
}
EOF
run_both "config-computed-key" "$TMP/computed.pp" '"-O2"'

# (d) $config lowers to the same value as the bare config(...) form.
cat > "$TMP/same.pp" <<'EOF'
with { config: { :k -> "v" } } {
  print($config("k") = config("k"))
  print($config("nope", "d") = config("nope", "d"))
}
EOF
run_both "config-equals-bare-form" "$TMP/same.pp" $'true\ntrue'

# (e) quasiquote parity: a $config template with an unquoted hole expands to
# code that evaluates to the same value as the bare form.
cat > "$TMP/qq.pp" <<'EOF'
defmacro mk(k) { quasiquote { $config(unquote(k)) } }
defmacro mkd(k, d) { quasiquote { $config(unquote(k), unquote(d)) } }
with { config: { :cc -> "clang" } } {
  print(mk("cc") = $config("cc"))
  print(mkd("x", "def") = $config("x", "def"))
}
EOF
run_both "config-qq-parity" "$TMP/qq.pp" $'true\ntrue'

# (f) arity is enforced from the table (1 or 2 args).
cat > "$TMP/arity.pp" <<'EOF'
print($config("a", "b", "c"))
EOF
got=$("$PP" "$TMP/arity.pp" 2>&1 || true)
if echo "$got" | grep -q '\$config expects'; then
  ok "config-arity-error-from-table"
else
  bad "config-arity-error-from-table" "got: $(printf '%q' "$got")"
fi

rm -rf "$TMP"
exit $fail
