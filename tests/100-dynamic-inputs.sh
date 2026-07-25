#!/usr/bin/env bash
# pins: LAW-16 LAW-18 LAW-21
# Glob observations invalidate on content changes and reuse old traces.
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
cat > "$TMP/glob.pp" <<EOF
force(node {
  perform log("GLOB")
  \$glob("$TMP/tree")
})
EOF

run_glob() {
  "$PP" --grant "fs:$TMP/tree:ro" "$TMP/glob.pp" > "$TMP/out" 2>&1
}

run_glob; assert "glob-cold" "GLOB" present
run_glob; assert "glob-hit" "GLOB" absent
printf 'two\n' > "$TMP/tree/b"
run_glob; assert "glob-add-invalidates" "GLOB" present
rm "$TMP/tree/b"
run_glob; assert "glob-revert-hits-old-trace" "GLOB" absent

if [ "$fail" -eq 0 ]; then echo "=== DYNAMIC INPUTS TEST PASSED ==="; fi
exit "$fail"
