#!/usr/bin/env bash
# pins: LAW-7 LAW-21
# Push stabilize test.
#
#   A 4-node program with a reverse-edge dependency graph:
#     a reads f1
#     b depends on a's result and reads f2
#     c depends on b's result
#     d reads f3 independently
#
#   On each cell change, push stabilize must retain clean evaluated thunks and
#   reset only the dirty nodes. This is the watch-pass retention boundary; the
#   store still supplies the same results on a later cold evaluation.
#
# Runs under an isolated HOME.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# Portable `timeout`: macOS ships without coreutils. Must be a real executable,
# not a shell function — `timeout N cmd &` has to put cmd's own pid in $! so
# `kill $!` reaches it (alarm(2) survives the exec chain).
if ! command -v timeout >/dev/null 2>&1; then
  SHIM_DIR=$(mktemp -d)
  printf '#!/bin/sh\nexec perl -e '\''alarm shift; exec @ARGV'\'' "$@"\n' > "$SHIM_DIR/timeout"
  chmod +x "$SHIM_DIR/timeout"
  PATH="$SHIM_DIR:$PATH"
fi

# assert_count (poll-until-count, from lib.sh) replaces this suite's former
# `sleep 4; grep -c` pairs: each step below writes a cell and then asserts the
# resulting re-evaluation count, waiting for it to arrive rather than sleeping.

# Write the 4-node program — use unquoted heredoc so $TMP expands to literal paths.
cat > "$TMP/stab.pp" <<EOF
let (a = node {
  perform log("A")
  slurp("$TMP/f1")
}, b = node {
  perform log("B")
  do {
    force(a)
    slurp("$TMP/f2")
  }
}, c = node {
  perform log("C")
  force(b)
}, d = node {
  perform log("D")
  slurp("$TMP/f3")
}) {
  force(c)
  force(d)
}
EOF

# Initial file contents
echo "F1-v1" > "$TMP/f1"
echo "F2-v1" > "$TMP/f2"
echo "F3-v1" > "$TMP/f3"

run_test() {
  local label="$1"
  local mode="$2"
  local out="$TMP/out-$label"
  local c_after_cutoff="$3"

  # Reset file contents (prior test may have modified them)
  echo "F1-v1" > "$TMP/f1"
  echo "F2-v1" > "$TMP/f2"
  echo "F3-v1" > "$TMP/f3"
  rm -rf "$TMP/.pp"

  # Start watch with stabilize in background
  timeout 35 "$PP" --watch $mode --watch-interval 0.3 --grant "fs:$TMP:ro" \
    "$TMP/stab.pp" > "$out" 2>&1 &
  local WATCH_PID=$!

  # --- Cold run assertions (poll until the cold pass has logged each node) ---
  new_watch_pass "$label-cold-A" "A" 1 "$out"
  new_watch_pass "$label-cold-B" "B" 1 "$out"
  new_watch_pass "$label-cold-C" "C" 1 "$out"
  new_watch_pass "$label-cold-D" "D" 1 "$out"

  # --- Step 1: A changes, B re-runs but returns the same f2 value, so cutoff
  # keeps C clean. D is independent. ---
  echo "F1-v2" > "$TMP/f1"
  new_watch_pass "$label-step1-A" "A" 2 "$out"
  new_watch_pass "$label-step1-B" "B" 2 "$out"
  new_watch_pass "$label-step1-C" "C" "$c_after_cutoff" "$out"
  new_watch_pass "$label-step1-D" "D" 1 "$out"

  # --- Step 2: change f3 — D dirty. Poll D first. ---
  echo "F3-v2" > "$TMP/f3"
  new_watch_pass "$label-step2-D" "D" 2 "$out"
  new_watch_pass "$label-step2-B" "B" 2 "$out"
  new_watch_pass "$label-step2-C" "C" "$c_after_cutoff" "$out"
  new_watch_pass "$label-step2-A" "A" 2 "$out"

  # --- Step 3: revert f1 — A/B/C dirty, D clean ---
  echo "F1-v3" > "$TMP/f1"
  new_watch_pass "$label-step3-A" "A" 3 "$out"
  new_watch_pass "$label-step3-B" "B" 3 "$out"
  new_watch_pass "$label-step3-C" "C" "$c_after_cutoff" "$out"
  new_watch_pass "$label-step3-D" "D" 2 "$out"

  kill $WATCH_PID 2>/dev/null
  wait $WATCH_PID 2>/dev/null || true
}

echo "--- push stabilize ---"
run_test "push-stabilize" "--stabilize" 1
echo "--- pull watch ---"
run_test "pull-watch" "" 1


exit $fail
