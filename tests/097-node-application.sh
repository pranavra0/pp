#!/usr/bin/env bash
# Node application is a persistent computation keyed by forced arguments and
# referenced values, while the existing scheduler remains the execution path.
# pins: LAW-6
# pins: LAW-20
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run() { "$PP" "$@" >"$TMP/out" 2>&1; }
count() { grep -c "$1" "$TMP/out" 2>/dev/null || true; }

cat > "$TMP/repeat.pp" <<'EOF'
node double(x) {
  perform log("BODY")
  x * 2
}
print(double(21))
print(double(21))
EOF

rm -rf "$TMP/.pp"
run "$TMP/repeat.pp"
[ "$(count BODY)" -eq 1 ] && grep -q '^42$' "$TMP/out" && grep -q '^42$' "$TMP/out" \
  && ok "equal-applications-share-one-computation" \
  || bad "equal-applications-share-one-computation" "$(cat "$TMP/out")"

run "$TMP/repeat.pp"
[ "$(count BODY)" -eq 0 ] && [ "$(grep -c '^42$' "$TMP/out")" -eq 2 ] \
  && ok "equal-applications-share-across-processes" \
  || bad "equal-applications-share-across-processes" "$(cat "$TMP/out")"

cat > "$TMP/arguments.pp" <<'EOF'
node identity(x) {
  perform log("BODY")
  x
}
print(identity(1))
print(identity(2))
print(identity(1))
EOF

rm -rf "$TMP/.pp"
run "$TMP/arguments.pp"
[ "$(count BODY)" -eq 2 ] && grep -q '^1$' "$TMP/out" \
  && [ "$(grep -c '^1$' "$TMP/out")" -eq 2 ] && grep -q '^2$' "$TMP/out" \
  && ok "different-arguments-have-different-keys" \
  || bad "different-arguments-have-different-keys" "$(cat "$TMP/out")"

cat > "$TMP/free-value.pp" <<'EOF'
let base = 10
node add(x) {
  perform log("BODY")
  base + x
}
print(add(1))
EOF

rm -rf "$TMP/.pp"
run "$TMP/free-value.pp"
[ "$(count BODY)" -eq 1 ] && grep -q '^11$' "$TMP/out" \
  && ok "first-free-value-build" \
  || bad "first-free-value-build" "$(cat "$TMP/out")"

sed -i 's/let base = 10/let base = 20/' "$TMP/free-value.pp"
run "$TMP/free-value.pp"
[ "$(count BODY)" -eq 1 ] && grep -q '^21$' "$TMP/out" \
  && ok "changed-free-value-rebuilds" \
  || bad "changed-free-value-rebuilds" "$(cat "$TMP/out")"

cat > "$TMP/forced-arguments.pp" <<'EOF'
node use(x) {
  perform log("BODY")
  x
}
def argument() {
  perform log("ARGUMENT")
  7
}
print(use(argument()))
EOF

rm -rf "$TMP/.pp"
run "$TMP/forced-arguments.pp"
argument_line=$(grep -n 'ARGUMENT' "$TMP/out" | cut -d: -f1)
body_line=$(grep -n 'BODY' "$TMP/out" | cut -d: -f1)
[ -n "$argument_line" ] && [ -n "$body_line" ] && [ "$argument_line" -lt "$body_line" ] \
  && ok "arguments-force-before-node-body" \
  || bad "arguments-force-before-node-body" "$(cat "$TMP/out")"

cat > "$TMP/map.pp" <<'EOF'
node increment(x) {
  perform log("BODY")
  x + 1
}
let inputs = list(
  node { perform log("ARGUMENT-1"); 1 },
  node { perform log("ARGUMENT-2"); 2 })
let results = force-deep(map(increment, inputs))
print(results)
EOF

rm -rf "$TMP/.pp"
PP_FORK_LOG="$TMP/forks.log" run --schedule parallel:2 "$TMP/map.pp"
[ "$(count BODY)" -eq 2 ] && [ "$(count ARGUMENT-)" -eq 2 ] \
  && grep -q '2' "$TMP/out" && grep -q '3' "$TMP/out" \
  && ok "mapped-node-applications-use-the-scheduler" \
  || bad "mapped-node-applications-use-the-scheduler" "$(cat "$TMP/out")"

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== NODE APPLICATION TEST PASSED ==="; fi
exit "$fail"
