#!/usr/bin/env bash
# tests/078 — typed $config observations.
#
# $config(key[, default]) reads scoped config, records a config: trace cell,
# and parses directly to EObserve (Config, args). There is no callable
# `config` compatibility primitive.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_one() {
  local name="$1" file="$2" expected="$3"
  local got
  got=$("$PP" "$file" 2>&1)
  if [ "$got" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "got: $(printf '%q' "$got")"
  fi
}

# (a) read a key set by the enclosing config extent.
cat > "$TMP/read.pp" <<'EOF'
with { config: { :cc -> "clang", :opt -> 2 } } {
  print($config("cc"))
  print($config("opt"))
}
EOF
run_one "config-read" "$TMP/read.pp" $'"clang"\n2'

# (b) default is used when the key is unset.
cat > "$TMP/default.pp" <<'EOF'
with { config: { :cc -> "clang" } } {
  print($config("missing", "fallback"))
}
EOF
run_one "config-default" "$TMP/default.pp" '"fallback"'

cat > "$TMP/lazy-default.pp" <<'EOF'
with { config: { :cc -> "clang" } } {
  print($config("cc", error("unused fallback")))
}
EOF
run_one "config-default-is-lazy" "$TMP/lazy-default.pp" '"clang"'

# (c) computed key expression: heads take expressions, not just literals.
cat > "$TMP/computed.pp" <<'EOF'
with { config: { :cflags -> "-O2" } } {
  print($config(string-append("cf", "lags")))
}
EOF
run_one "config-computed-key" "$TMP/computed.pp" '"-O2"'

# (d) the removed bare config call is an ordinary unresolved function.
cat > "$TMP/raw.pp" <<'EOF'
print(config("k"))
EOF
got=$("$PP" "$TMP/raw.pp" 2>&1 || true)
if echo "$got" | grep -q 'unbound symbol: config'; then
  ok "bare-config-removed"
else
  bad "bare-config-removed" "got: $(printf '%q' "$got")"
fi

# (e) quasiquote parity: a $config template with an unquoted hole expands to
# the same typed observation AST.
cat > "$TMP/qq.pp" <<'EOF'
defmacro mk(k) { quasiquote { $config(unquote(k)) } }
defmacro mkd(k, d) { quasiquote { $config(unquote(k), unquote(d)) } }
with { config: { :cc -> "clang" } } {
  print(mk("cc") = $config("cc"))
  print(mkd("x", "def") = $config("x", "def"))
}
EOF
run_one "config-qq-parity" "$TMP/qq.pp" $'true\ntrue'

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
