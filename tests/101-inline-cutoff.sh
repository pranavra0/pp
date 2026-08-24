#!/usr/bin/env bash
# pins: LAW-7 LAW-21
# Pull and push watch agree on results; inline children reconstruct on change.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

if ! command -v timeout >/dev/null 2>&1; then
  SHIM_DIR=$(mktemp -d)
  printf '#!/bin/sh\nexec perl -e '\''alarm shift; exec @ARGV'\'' "$@"\n' > "$SHIM_DIR/timeout"
  chmod +x "$SHIM_DIR/timeout"
  PATH="$SHIM_DIR:$PATH"
fi

cat > "$TMP/inline.pp" <<EOF
force(node {
  perform log("PARENT")
  force(node {
    perform log("CHILD")
    do { slurp("$TMP/input"); "stable" }
  })
})
EOF

run_mode() {
  local label="$1" mode="$2" parent_count="$3" out="$TMP/$1.out"
  printf 'one\n' > "$TMP/input"
  rm -rf "$TMP/.pp"
  timeout 20 "$PP" --watch $mode --watch-interval 0.2 \
    --grant "fs:$TMP:ro" "$TMP/inline.pp" > "$out" 2>&1 &
  local watch_pid=$!
  new_watch_pass "$label-cold-child" "CHILD" 1 "$out"
  new_watch_pass "$label-cold-parent" "PARENT" 1 "$out"
  printf 'two\n' > "$TMP/input"
  new_watch_pass "$label-child-recomputed" "CHILD" 2 "$out"
  new_watch_pass "$label-parent-work" "PARENT" "$parent_count" "$out"
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
}

run_mode "pull" "" 2
run_mode "push" "--stabilize" 2

# A fresh process has no executable inline-child closure in memory. It
# recursively validates the stored child trace, serves the parent when that
# trace is valid, and reruns the parent to reconstruct the child after the
# child's world input changes.
printf 'one\n' > "$TMP/input"
rm -rf "$TMP/.pp"
"$PP" --grant "fs:$TMP:ro" "$TMP/inline.pp" >"$TMP/fresh-cold.out" 2>&1
"$PP" --grant "fs:$TMP:ro" "$TMP/inline.pp" >"$TMP/fresh-hit.out" 2>&1
if grep -q "PARENT\\|CHILD" "$TMP/fresh-hit.out"; then
  bad "fresh-valid-parent-hit" "$(cat "$TMP/fresh-hit.out")"
else
  ok "fresh-valid-parent-hit"
fi
printf 'two\n' > "$TMP/input"
"$PP" --grant "fs:$TMP:ro" "$TMP/inline.pp" >"$TMP/fresh-stale.out" 2>&1
if grep -q "PARENT" "$TMP/fresh-stale.out" && grep -q "CHILD" "$TMP/fresh-stale.out"; then
  ok "fresh-stale-child-reconstructed"
else
  bad "fresh-stale-child-reconstructed" "$(cat "$TMP/fresh-stale.out")"
fi
"$PP" --grant "fs:$TMP:ro" "$TMP/inline.pp" >"$TMP/fresh-rehit.out" 2>&1
if grep -q "PARENT\\|CHILD" "$TMP/fresh-rehit.out"; then
  bad "fresh-rebuilt-parent-rehits" "$(cat "$TMP/fresh-rehit.out")"
else
  ok "fresh-rebuilt-parent-rehits"
fi

if [ "$fail" -eq 0 ]; then echo "=== INLINE CUTOFF TEST PASSED ==="; fi
exit "$fail"
