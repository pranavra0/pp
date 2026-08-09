#!/usr/bin/env bash
# pins: LAW-17 LAW-19 LAW-21
# Every observable facet of a data value must be identical before and after
# persistence. This catches codecs that reorder or duplicate collections.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/value.pp" <<'EOF'
let value = force(node {
  {"z" -> 1,
   "a" -> 2,
   "z" -> 3,
   "set" -> hash-set("z", "a", "z"),
   "nested" -> {"b" -> 2, "a" -> 1}}
})
print(value)
print(value = {"nested" -> {"a" -> 1, "b" -> 2},
               "set" -> hash-set("a", "z"),
               "a" -> 2,
               "z" -> 3})
print(map-keys(value))
print(set->list(hash-map-get(value, "set")))
EOF

"$PP" --why "$TMP/value.pp" > "$TMP/cold.out" 2> "$TMP/cold.err"
"$PP" --why "$TMP/value.pp" > "$TMP/warm.out" 2> "$TMP/warm.err"
if cmp -s "$TMP/cold.out" "$TMP/warm.out"; then
  ok "cache-value-byte-equivalence"
else
  bad "cache-value-byte-equivalence" \
    "cold: $(cat "$TMP/cold.out")" "warm: $(cat "$TMP/warm.out")"
fi
if grep -q "miss" "$TMP/cold.err" && grep -q "hit" "$TMP/warm.err"; then
  ok "cache-value-exercised-cold-and-hit"
else
  bad "cache-value-exercised-cold-and-hit" \
    "cold: $(cat "$TMP/cold.err")" "warm: $(cat "$TMP/warm.err")"
fi
if grep -qx "true" "$TMP/cold.out"; then
  ok "cache-value-semantic-equality"
else
  bad "cache-value-semantic-equality" "output: $(cat "$TMP/cold.out")"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== CACHE VALUE EQUIVALENCE TEST PASSED ==="; fi
exit "$fail"
