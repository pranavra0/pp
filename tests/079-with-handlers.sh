#!/usr/bin/env bash
# tests/079 — B9: the `with { }` handler clause is regularized to a map-valued
# `handlers: { :name -> fn, ... }` clause (the `:` rule — closed clause header
# taking a map), replacing the old two-token `handler NAME: fn` key.
#
# The `with-handler(name = fn, ...)` PRIMITIVE form is unchanged (tests/069);
# this covers the combined `with { }` clause only.
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

# (a) a handlers: map installs multiple effect handlers.
cat > "$TMP/multi.pp" <<'EOF'
with {
  handlers: {
    :log -> fn(msg) { print(string-append("LOG: ", msg)) },
    :ask -> fn(n) { n * 10 }
  }
} {
  perform log("hi")
  print(perform ask(5))
}
EOF
run_both "handlers-map-multi" "$TMP/multi.pp" $'"LOG: hi"\n50'

# (b) a single handler in the map.
cat > "$TMP/one.pp" <<'EOF'
with { handlers: { :ask -> fn(n) { n + 1 } } } {
  print(perform ask(41))
}
EOF
run_both "handlers-map-single" "$TMP/one.pp" '42'

# (c) combined with caps and config clauses (canonical nesting).
cat > "$TMP/combo.pp" <<'EOF'
with {
  config: { :prefix -> "> " },
  handlers: { :log -> fn(m) { print(string-append($config("prefix"), m)) } }
} {
  perform log("done")
}
EOF
run_both "handlers-with-config" "$TMP/combo.pp" '"> done"'

# (d) the removed two-token `handler NAME:` key errors (both backends), with a
# message listing the table's clause keywords.
cat > "$TMP/old.pp" <<'EOF'
with { handler log: fn(m) { print(m) } } { perform log("x") }
EOF
got_tw=$("$PP" "$TMP/old.pp" 2>&1 || true)
got_bc=$("$PP" --bytecode "$TMP/old.pp" 2>&1 || true)
if [[ "$got_tw" == *"handlers:"* ]] && [[ "$got_bc" == *"handlers:"* ]]; then
  ok "old-handler-key-removed"
else
  bad "old-handler-key-removed" "tw: $got_tw" "bc: $got_bc"
fi

# (e) handlers: must take a map literal, not a bare expression.
cat > "$TMP/notmap.pp" <<'EOF'
let h = 5
with { handlers: h } { perform log("x") }
EOF
got=$("$PP" "$TMP/notmap.pp" 2>&1 || true)
if [[ "$got" == *"map literal"* ]]; then
  ok "handlers-requires-map-literal"
else
  bad "handlers-requires-map-literal" "got: $got"
fi

rm -rf "$TMP"
exit $fail
