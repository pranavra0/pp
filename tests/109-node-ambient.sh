#!/usr/bin/env bash
# Persistent nodes have a closed dependency surface: ambient capability state,
# runtime configuration, and fresh-name allocation are scripting-tier inputs,
# not silently untracked node dependencies.
# pins: LAW-6 LAW-16 LAW-20
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run_case() {
  local name="$1" expected="$2"
  shift 2
  "$PP" "$@" >"$TMP/out" 2>&1
  if grep -qF "$expected" "$TMP/out"; then
    ok "$name"
  else
    bad "$name" "expected: $expected" "$(cat "$TMP/out")"
  fi
}

cat >"$TMP/gensym.pp" <<'EOF'
print(force(node { gensym() }))
EOF
run_case node-gensym-rejected \
  "gensym: may not be called inside a node body (scripting-tier only)" \
  "$TMP/gensym.pp"

cat >"$TMP/capabilities.pp" <<'EOF'
print(force(node { capability?(current-capabilities()) }))
EOF
run_case node-capability-observation-rejected \
  "current-capabilities: may not be called inside a node body (scripting-tier only)" \
  "$TMP/capabilities.pp"

cat >"$TMP/runtime-config.pp" <<'EOF'
load("stdlib/runtime.pp")
configure-runtime({:schedule -> schedule-serial()})
print(force(node { runtime-config() }))
EOF
run_case node-runtime-config-rejected \
  "runtime-config: may not be called inside a node body (scripting-tier only)" \
  "$TMP/runtime-config.pp"

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== NODE AMBIENT TEST PASSED ==="; fi
exit "$fail"
