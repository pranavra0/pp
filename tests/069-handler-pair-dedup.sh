#!/usr/bin/env bash
# tests/069 — A′5: one `with-handler(name = fn, …)` pair parser, two contexts.
#
# The pair-parsing loop used to be copied in the normal reader and the
# quasiquote reader (MASTER-PLAN A′5's cited example). They had drifted: the
# quasiquote copy silently accepted a trailing comma while the normal copy
# rejected it — like every other comma list in the grammar. They are now one
# function (Reader_braces.parse_handler_pairs), so:
#   (a) with-handler runs, both backends, in ordinary code;
#   (b) a with-handler quasiquote template expands and runs identically on both
#       backends (the pair loop builds the same data either way);
#   (c) a trailing comma is rejected in BOTH readers (the drift is gone).
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

run_both() {
  local name="$1" file="$2" expected="$3"
  local tw bc
  tw=$("$PP"            "$file" 2>&1)
  bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$tw" = "$expected" ] && [ "$bc" = "$expected" ]; then ok "$name"
  else bad "$name" "expected: $(printf '%q' "$expected")" \
                   "tw:       $(printf '%q' "$tw")" \
                   "bc:       $(printf '%q' "$bc")"; fi
}

# (a) ordinary with-handler, symbol + keyword names.
cat > "$TMP/n.pp" <<'EOF'
def sink(m) { m }
print(with-handler(log = sink, :warn = sink) { perform log("hi") })
EOF
run_both "normal-with-handler" "$TMP/n.pp" '"hi"'

# (b) with-handler quasiquote template expands+runs, both backends agree.
cat > "$TMP/q.pp" <<'EOF'
def h(m) { m }
defmacro mk() { quasiquote { with-handler(log = h) { perform log("hi") } } }
print(mk())
EOF
run_both "qq-with-handler-template" "$TMP/q.pp" '"hi"'

# (c) trailing comma rejected in BOTH readers (consistency fix).
cat > "$TMP/tc-normal.pp" <<'EOF'
def h(m) { m }
with-handler(log = h,) { perform log("x") }
EOF
gotn=$("$PP" "$TMP/tc-normal.pp" 2>&1 || true)
cat > "$TMP/tc-qq.pp" <<'EOF'
def h(m) { m }
defmacro mk() { quasiquote { with-handler(log = h,) { 1 } } }
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
