#!/usr/bin/env bash
# tests/079 — B9: the `with { }` handler clause is regularized to a map-valued
# `handlers: { :name -> fn, ... }` clause (the `:` rule — closed clause header
# taking a map), replacing the old two-token `handler NAME: fn` key.
#
# The `with-handler(name = fn, ...)` PRIMITIVE form is unchanged (tests/069);
# this covers the combined `with { }` clause only.
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

# (a) a handlers: map installs multiple effect handlers.
cat > "$TMP/multi.pp" <<'EOF'
with {
  handlers: {
    :log! -> fn(msg) { print(string-append("LOG: ", msg)) },
    :ask -> fn(n) { n * 10 }
  }
} {
  log!("hi")
  print(perform ask(5))
}
EOF
run_one "handlers-map-multi" "$TMP/multi.pp" $'"LOG: hi"\n50'

# (b) a single handler in the map.
cat > "$TMP/one.pp" <<'EOF'
with { handlers: { :ask -> fn(n) { n + 1 } } } {
  print(perform ask(41))
}
EOF
run_one "handlers-map-single" "$TMP/one.pp" '42'

# (c) combined with caps and config clauses (canonical nesting).
cat > "$TMP/combo.pp" <<'EOF'
with {
  config: { :prefix -> "> " },
  handlers: { :log! -> fn(m) { print(string-append($config("prefix"), m)) } }
} {
  log!("done")
}
EOF
run_one "handlers-with-config" "$TMP/combo.pp" '"> done"'

# (d) the removed two-token `handler NAME:` key errors, with a
# message listing the table's clause keywords.
cat > "$TMP/old.pp" <<'EOF'
with { handler log: fn(m) { print(m) } } { log!("x") }
EOF
got=$("$PP" "$TMP/old.pp" 2>&1 || true)
if [[ "$got" == *"handlers:"* ]]; then
  ok "old-handler-key-removed"
else
  bad "old-handler-key-removed" "got: $got"
fi

# (e) handlers: must take a map literal, not a bare expression.
cat > "$TMP/notmap.pp" <<'EOF'
let h = 5
with { handlers: h } { log!("x") }
EOF
got=$("$PP" "$TMP/notmap.pp" 2>&1 || true)
if [[ "$got" == *"map literal"* ]]; then
  ok "handlers-requires-map-literal"
else
  bad "handlers-requires-map-literal" "got: $got"
fi

rm -rf "$TMP"
exit $fail
