#!/usr/bin/env bash
# The legacy depfile adapter is scripting-only: a tool's self-report cannot
# close the ambient reads of a cacheable process.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cat > "$TMP/denied.pp" <<'EOF'
force(node {
  perform run-dep!("out.d", "sh", "-c", "printf escaped > escaped")
})
EOF
"$PP" --grant process "$TMP/denied.pp" >"$TMP/out" 2>&1
if grep -q "scripting-tier only" "$TMP/out" && [ ! -e "$TMP/escaped" ]; then
  ok "depfile-node-denied"
else
  bad "depfile-node-denied" "$(cat "$TMP/out")"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== DEPFILE ADAPTER (Q2) TEST PASSED ==="; fi
exit $fail
