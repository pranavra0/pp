#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib.sh"

"$PP" tests/107-custom-scheduler.pp > "$TMP/out" 2>&1
code=$?
if [ "$code" -eq 0 ] && grep -q '"custom"' "$TMP/out" && grep -q '^42$' "$TMP/out"; then
  ok "pp-custom-scheduler"
else
  bad "pp-custom-scheduler" "exit=$code" "$(cat "$TMP/out")"
fi

cat > "$TMP/bad.pp" <<'EOF'
load("stdlib/runtime.pp")
def choose(jobs) {{:mode -> :serial, :batches -> vec[vec[0], vec[0]]}}
configure-runtime({:schedule -> schedule-custom(choose)})
node value() { 1 }
print(value())
EOF
"$PP" "$TMP/bad.pp" > "$TMP/bad-out" 2>&1
code=$?
if [ "$code" -ne 0 ] && grep -q "every job exactly once" "$TMP/bad-out"; then
  ok "pp-custom-scheduler-boundary"
else
  bad "pp-custom-scheduler-boundary" "exit=$code" "$(cat "$TMP/bad-out")"
fi
exit "$fail"
