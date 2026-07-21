#!/usr/bin/env bash
# The semantic spine stays one path from node application through identity,
# cache lookup, and rebuild: arguments are strict, equal applications hit, and
# changing a referenced value rebuilds the persistent computation.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run() { "$PP" "$TMP/spine.pp" >"$TMP/out" 2>&1; }
count() { grep -c "$1" "$TMP/out" 2>/dev/null || true; }

cat > "$TMP/spine.pp" <<'EOF'
let base = 10
node add(x) {
  perform log("BODY")
  base + x
}
def argument() {
  perform log("ARGUMENT")
  1
}
print(add(argument()))
EOF

rm -rf "$TMP/.pp"
run
argument_line=$(grep -n 'ARGUMENT' "$TMP/out" | cut -d: -f1)
body_line=$(grep -n 'BODY' "$TMP/out" | cut -d: -f1)
[ "$(count BODY)" -eq 1 ] && [ "$(count ARGUMENT)" -eq 1 ] \
  && [ -n "$argument_line" ] && [ -n "$body_line" ] \
  && [ "$argument_line" -lt "$body_line" ] \
  && grep -q '^11$' "$TMP/out" \
  && ok "application-to-rebuild-first-run" \
  || bad "application-to-rebuild-first-run" "$(cat "$TMP/out")"

run
[ "$(count BODY)" -eq 0 ] && [ "$(count ARGUMENT)" -eq 1 ] \
  && grep -q '^11$' "$TMP/out" \
  && ok "application-to-cache-hit-second-run" \
  || bad "application-to-cache-hit-second-run" "$(cat "$TMP/out")"

sed -i 's/let base = 10/let base = 20/' "$TMP/spine.pp"
run
[ "$(count BODY)" -eq 1 ] && grep -q '^21$' "$TMP/out" \
  && ok "identity-to-rebuild-on-free-value-change" \
  || bad "identity-to-rebuild-on-free-value-change" "$(cat "$TMP/out")"

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== SEMANTIC SPINE TEST PASSED ==="; fi
exit "$fail"
