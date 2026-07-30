#!/usr/bin/env bash
# tests/069 — one `with-handler(name = fn, …)` pair parser, two contexts.
#
# The pair-parsing loop used to be copied in the normal reader and the
# quasiquote reader. They had drifted: the quasiquote copy silently accepted
# a trailing comma while the normal copy rejected it — like every other
# comma list in the grammar. They are now one function
# (Reader_braces.parse_handler_pairs), so:
#   (a) with-handler runs in ordinary code;
#   (b) a with-handler quasiquote template expands and runs identically;
#   (c) a trailing comma is rejected in BOTH readers (the drift is gone).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_one() {
  local name="$1" file="$2" expected="$3"
  local got
  got=$("$PP" "$file" 2>&1)
  if [ "$got" = "$expected" ]; then ok "$name"
  else bad "$name" "expected: $(printf '%q' "$expected")" \
                   "got:       $(printf '%q' "$got")"; fi
}

# (a) ordinary with-handler, symbol + keyword names.
cat > "$TMP/n.pp" <<'EOF'
def sink(m) { m }
print(with-handler(log! = sink, :warn = sink) { log!("hi") })
EOF
run_one "normal-with-handler" "$TMP/n.pp" '"hi"'

# (b) with-handler quasiquote template expands+runs.
cat > "$TMP/q.pp" <<'EOF'
def h(m) { m }
defmacro mk() { quasiquote { with-handler(log! = h) { log!("hi") } } }
print(mk())
EOF
run_one "qq-with-handler-template" "$TMP/q.pp" '"hi"'

# (c) trailing comma rejected in BOTH readers (consistency fix).
cat > "$TMP/tc-normal.pp" <<'EOF'
def h(m) { m }
with-handler(log! = h,) { log!("x") }
EOF
gotn=$("$PP" "$TMP/tc-normal.pp" 2>&1 || true)
cat > "$TMP/tc-qq.pp" <<'EOF'
def h(m) { m }
defmacro mk() { quasiquote { with-handler(log! = h,) { 1 } } }
print(mk())
EOF
gotq=$("$PP" "$TMP/tc-qq.pp" 2>&1 || true)
if echo "$gotn" | grep -q "handler name must be a symbol or keyword" \
   && echo "$gotq" | grep -q "handler name must be a symbol or keyword"; then
  ok "trailing-comma-rejected-in-both-readers"
else
  bad "trailing-comma-rejected-in-both-readers" \
      "normal: $(printf '%q' "$gotn")" "qq: $(printf '%q' "$gotq")"
fi

exit $fail
