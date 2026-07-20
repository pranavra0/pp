#!/usr/bin/env bash
# pins: LAW-2 LAW-3 LAW-4
# Issue 19: scope construction, force-cycle diagnostics, and mutual-binding
# identity agree across the language's scope forms.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

fail=0

cat > "$TMP/let.pp" <<'EOF'
print(let (right = left + 1, left = 1) { right })
EOF
if [ "$("$PP" "$TMP/let.pp" 2>&1)" = '2' ]; then
  ok "mutual-let-order-independent"
else
  bad "mutual-let-order-independent"
fi

cat > "$TMP/do.pp" <<'EOF'
print(do { print(f(2)); def f(x) { x + 1 }; 0 })
EOF
if [ "$("$PP" "$TMP/do.pp" 2>&1)" = $'3\n0' ]; then
  ok "block-function-prebinding"
else
  bad "block-function-prebinding"
fi

cat > "$TMP/top.pp" <<'EOF'
print(f(2))
def f(x) { x + 1 }
EOF
if [ "$("$PP" "$TMP/top.pp" 2>&1)" = '3' ]; then
  ok "top-level-function-prebinding"
else
  bad "top-level-function-prebinding"
fi

cat > "$TMP/module.pp" <<'EOF'
print(module { print(f(2)); def f(x) { x + 1 }; let result = 0 })
EOF
if "$PP" "$TMP/module.pp" >"$TMP/module.out" 2>&1 &&
   grep -q '^3$' "$TMP/module.out"; then
  ok "module-function-prebinding"
else
  bad "module-function-prebinding" "$(cat "$TMP/module.out" 2>/dev/null)"
fi

cat > "$TMP/forward.pp" <<'EOF'
let first = second + 1
let second = 2
print(first)
EOF
if "$PP" "$TMP/forward.pp" >"$TMP/forward.out" 2>&1; then
  bad "value-statement-timing" "forward reference unexpectedly succeeded"
elif grep -q 'second: referenced before its definition' "$TMP/forward.out"; then
  ok "value-statement-timing"
else
  bad "value-statement-timing" "$(cat "$TMP/forward.out")"
fi

cat > "$TMP/cycle.pp" <<'EOF'
print(let (left = right, right = left) { left })
EOF
if "$PP" "$TMP/cycle.pp" >"$TMP/cycle.out" 2>&1; then
  bad "named-force-cycle" "cycle unexpectedly succeeded"
elif grep -q 'cyclic binding: left -> right -> left' "$TMP/cycle.out"; then
  ok "named-force-cycle"
else
  bad "named-force-cycle" "$(cat "$TMP/cycle.out")"
fi

cat > "$TMP/order-a.pp" <<'EOF'
print(let (a = 1, b = 2) { a + b })
EOF
cat > "$TMP/order-b.pp" <<'EOF'
print(let (b = 2, a = 1) { a + b })
EOF
if "$PP" --compare-hash "$TMP/order-a.pp" "$TMP/order-b.pp" >/dev/null 2>&1; then
  ok "mutual-let-hash-order"
else
  bad "mutual-let-hash-order"
fi

cat > "$TMP/star-a.pp" <<'EOF'
print(let* (a = 1, b = 2) { a + b })
EOF
cat > "$TMP/star-b.pp" <<'EOF'
print(let* (b = 2, a = 1) { a + b })
EOF
if "$PP" --compare-hash "$TMP/star-a.pp" "$TMP/star-b.pp" >/dev/null 2>&1; then
  bad "sequential-let-hash-order" "let* order was canonicalized"
else
  ok "sequential-let-hash-order"
fi

rm -rf "$TMP"
exit "$fail"
