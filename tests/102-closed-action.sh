#!/usr/bin/env bash
# `run-closed!` accepts only immutable tool/input blobs, rejects path escape
# before execution, and either enters a network/filesystem namespace or fails
# explicitly when the host cannot provide that namespace.
# pins: LAW-16 LAW-18 LAW-22
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run() { "$PP" "$@" >"$TMP/out" 2>&1; }

cat >"$TMP/no-cap.pp" <<'EOF'
perform run-closed!({
  :tool -> blob("not-a-tool"),
  :args -> [],
  :inputs -> {},
  :outputs -> []
})
EOF
run "$TMP/no-cap.pp"
if grep -q "no process authority" "$TMP/out"; then ok "closed-no-cap"
else bad "closed-no-cap" "$(cat "$TMP/out")"; fi

cat >"$TMP/traversal.pp" <<'EOF'
let tool = blob("not-a-tool")
perform run-closed!({
  :tool -> tool,
  :args -> [],
  :inputs -> {"../escape" -> blob("input")},
  :outputs -> []
})
EOF
run --grant process "$TMP/traversal.pp"
if grep -q "rejects non-canonical input path" "$TMP/out"; then ok "closed-input-traversal"
else bad "closed-input-traversal" "$(cat "$TMP/out")"; fi

cat >"$TMP/output-traversal.pp" <<'EOF'
let tool = blob("not-a-tool")
perform run-closed!({
  :tool -> tool,
  :args -> [],
  :inputs -> {},
  :outputs -> ["../escape"]
})
EOF
run --grant process "$TMP/output-traversal.pp"
if grep -q "rejects non-canonical output path" "$TMP/out"; then ok "closed-output-traversal"
else bad "closed-output-traversal" "$(cat "$TMP/out")"; fi

tool=
for candidate in /usr/bin/cosign-linux-amd64 /usr/bin/init.lxc.static; do
  if [ -x "$candidate" ]; then tool="$candidate"; break; fi
done

if [ -n "$tool" ]; then
  cat >"$TMP/execute.pp" <<EOF
let tool = blob(slurp("$tool"))
let result = perform run-closed!({
  :tool -> tool,
  :args -> ["--help"],
  :inputs -> {},
  :outputs -> []
})
print(hash-map-get(result, :exit))
EOF
  run --grant process --grant "fs:$tool:ro" "$TMP/execute.pp"
  if grep -q "closed Linux runner unavailable" "$TMP/out"; then
    ok "closed-host-fails-closed"
  elif grep -qE '^[0-9]+$' "$TMP/out"; then
    ok "closed-static-tool-executes"
  else
    bad "closed-static-tool-executes" "$(cat "$TMP/out")"
  fi
else
  ok "closed-static-tool-unavailable"
fi

rm -rf "$TMP"
exit "$fail"
