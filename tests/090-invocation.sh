#!/usr/bin/env bash
# Invocation validation rejects invalid retained-root counts, and program argv
# contains only tokens after `--`, distinct from pp command options and files.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/argv.pp" <<'EOF'
print(argv())
EOF
out=$(new_command --grant process "$TMP/argv.pp" -- alpha --beta)
if [ "$out" = '("alpha" "--beta")' ]; then ok "program-argv-separated"
else bad "program-argv-separated" "got: $out"; fi

ec=0
new_command --gc-keep-epochs 0 gc >"$TMP/invalid-out" 2>&1 || ec=$?
if [ "$ec" -ne 0 ] && grep -q 'invalid --gc-keep-epochs' "$TMP/invalid-out"; then
  ok "invalid-invocation-rejected"
else
  bad "invalid-invocation-rejected" "exit=$ec" "$(cat "$TMP/invalid-out")"
fi

rm -rf "$TMP"
exit $fail
