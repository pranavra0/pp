#!/usr/bin/env bash
# pins: LAW-16 LAW-18 LAW-21
# Tree observations invalidate on content changes and reuse old traces.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

assert() {
  local name="$1" pattern="$2" mode="$3"
  if grep -qE "$pattern" "$TMP/out"; then actual=present; else actual=absent; fi
  if [ "$actual" = "$mode" ]; then ok "$name"
  else bad "$name" "expected $pattern $mode" "$(cat "$TMP/out")"; fi
}

mkdir -p "$TMP/tree"
printf 'one\n' > "$TMP/tree/a"
cat > "$TMP/tree.pp" <<EOF
force(node {
  log!("TREE")
  \$tree("$TMP/tree")
})
EOF

run_tree() {
  "$PP" --grant "fs:$TMP/tree:ro" "$TMP/tree.pp" > "$TMP/out" 2>&1
}

run_tree; assert "tree-cold" "TREE" present
run_tree; assert "tree-hit" "TREE" absent
printf 'two\n' > "$TMP/tree/b"
run_tree; assert "tree-add-invalidates" "TREE" present
rm "$TMP/tree/b"
run_tree; assert "tree-revert-hits-old-trace" "TREE" absent

if [ "$fail" -eq 0 ]; then echo "=== DYNAMIC INPUTS TEST PASSED ==="; fi
exit "$fail"
