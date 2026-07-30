#!/usr/bin/env bash
# pins: LAW-8
# Ephemeral thunks memoize only their own force and never share runtime state.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/ephemeral.pp" <<'EOF'
let delayed = delay(do { log!("DELAYED"); 5 })
print(force(delayed))
print(force(delayed))

print(force(delay(do { log!("FRESH"); 6 })))
print(force(delay(do { log!("FRESH"); 6 })))

def twice() {
  let (x = do { log!("EPHEMERAL"); 7 }) { x }
}
print(twice())
print(twice())
EOF

"$PP" "$TMP/ephemeral.pp" > "$TMP/out" 2>&1
if [ "$(grep -c 'DELAYED' "$TMP/out" || true)" -eq 1 ] &&
   [ "$(grep -c 'FRESH' "$TMP/out" || true)" -eq 2 ] &&
   [ "$(grep -c 'EPHEMERAL' "$TMP/out" || true)" -eq 2 ] &&
   [ "$(grep -c '^5$' "$TMP/out" || true)" -eq 2 ] &&
   [ "$(grep -c '^6$' "$TMP/out" || true)" -eq 2 ] &&
   [ "$(grep -c '^7$' "$TMP/out" || true)" -eq 2 ]; then
  ok "ephemeral-thunks-are-fresh"
else
  bad "ephemeral-thunks-are-fresh" \
    "expected one effect per thunk and no sharing between equal thunks" \
    "$(cat "$TMP/out")"
fi

if [ "$fail" -eq 0 ]; then echo "=== THUNK CONTRACT TEST PASSED ==="; fi
exit "$fail"
