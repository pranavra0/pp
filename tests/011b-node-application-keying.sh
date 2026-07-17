#!/usr/bin/env bash
# tests/011b — node application keying (SPEC LAW 6/20): defnode creates a
# persistent node thunk keyed on the argument value hashes. Arguments that
# affect the result change the key; unused arguments do not; captured
# variables matter but the argument value does not.
#
# Pins: LAW 6/20 (node application keying).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# (a) basic defnode: different args → different keys
rm -rf "$TMP/.pp"
cat > "$TMP/a.ppx" <<'EOF'
(defnode (inc x) (+ x 1))
(print (inc 5))
(print (inc 6))
(print (inc 5))
EOF
got=$("$PP" why "$TMP/a.ppx" 2>&1)
a_misses=$(echo "$got" | grep -c 'miss')
if [ "$a_misses" = "2" ]; then
  ok "different-args-different-keys"
else
  bad "different-args-different-keys" "expected 2 misses, got $a_misses" "$got"
fi
a_ids=$(echo "$got" | grep -oP 'node \K[a-f0-9]+(?=:)' | sort -u)
if [ "$(echo "$a_ids" | wc -l)" = "2" ]; then
  ok "different-args-two-unique-node-ids"
else
  bad "different-args-two-unique-node-ids" "expected 2 unique node IDs" "$a_ids"
fi

# (b) unused argument → same key
rm -rf "$TMP/.pp"
cat > "$TMP/b.ppx" <<'EOF'
(defnode (const a b) a)
(print (const 1 2))
(print (const 1 3))
EOF
got=$("$PP" why "$TMP/b.ppx" 2>&1)
b_misses=$(echo "$got" | grep -c 'miss')
if [ "$b_misses" = "1" ]; then
  ok "unused-arg-same-key"
else
  bad "unused-arg-same-key" "expected 1 miss, got $b_misses" "$got"
fi

# (c) captured variable: different args, same key (only captured y matters)
rm -rf "$TMP/.pp"
cat > "$TMP/c.ppx" <<'EOF'
(let (y 42)
  (defnode (cap x) y)
  (print (cap 1))
  (print (cap 2)))
EOF
got=$("$PP" why "$TMP/c.ppx" 2>&1)
c_misses=$(echo "$got" | grep -c 'miss')
if [ "$c_misses" = "1" ]; then
  ok "captured-var-same-key"
else
  bad "captured-var-same-key" "expected 1 miss, got $c_misses" "$got"
fi

# (d) different captured y → different key
rm -rf "$TMP/.pp"
cat > "$TMP/d1.ppx" <<'EOF'
(let (y 42)
  (defnode (cap x) y)
  (print (cap 1)))
EOF
cat > "$TMP/d2.ppx" <<'EOF'
(let (y 99)
  (defnode (cap x) y)
  (print (cap 1)))
EOF
"$PP" "$TMP/d1.ppx" > /dev/null 2>&1
got=$("$PP" why "$TMP/d2.ppx" 2>&1)
d_misses=$(echo "$got" | grep -c 'miss')
if [ "$d_misses" = "1" ]; then
  ok "different-captured-var-different-key"
else
  bad "different-captured-var-different-key" "expected 1 miss, got $d_misses" "$got"
fi

# (e) defnode inside do block: differential
cat > "$TMP/e.ppx" <<'EOF'
(do
  (defnode (nested x) x)
  (print (nested 10))
  (print (nested 10)))
EOF
got_tw=$("$PP"             "$TMP/e.ppx" 2>&1)
got_bc=$("$PP" --bytecode  "$TMP/e.ppx" 2>&1)
if [ "$got_tw" = "$got_bc" ] && [ "$got_tw" = "10
10" ]; then
  ok "defnode-in-do"
else
  bad "defnode-in-do" "tw: $got_tw" "bc: $got_bc"
fi

# (f) defnode inside module: differential
cat > "$TMP/f.ppx" <<'EOF'
(import (module
  (defnode (nested x) x)))
(print (nested 20))
(print (nested 20))
EOF
got_tw=$("$PP"             "$TMP/f.ppx" 2>&1)
got_bc=$("$PP" --bytecode  "$TMP/f.ppx" 2>&1)
if [ "$got_tw" = "$got_bc" ] && [ "$got_tw" = "20
20" ]; then
  ok "defnode-in-module"
else
  bad "defnode-in-module" "tw: $got_tw" "bc: $got_bc"
fi

rm -rf "$TMP"
exit $fail
