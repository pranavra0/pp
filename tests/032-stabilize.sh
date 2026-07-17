#!/usr/bin/env bash
# Push stabilize differential test.
#
#   A 4-node program with a reverse-edge dependency graph:
#     a reads f1
#     b forces a (trace transitively includes f1) and reads f2
#     c forces b (trace transitively includes f1 + f2)
#     d reads f3 independently
#
#   On each cell change, push stabilize must produce the same
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
  local out="$TMP/out-$label"
  local step2_B=2 step2_C=2 step3_A=3 step3_B=3 step3_C=3

  # Reset file contents (prior test may have modified them)
  echo "F1-v1" > "$TMP/f1"
  echo "F2-v1" > "$TMP/f2"
  echo "F3-v1" > "$TMP/f3"
  rm -rf "$TMP/.pp"

  # Start watch with stabilize in background
  timeout 35 "$PP" --watch --stabilize --watch-interval 0.3 --grant "fs:$TMP:ro" \
    "$TMP/stab.pp" > "$out" 2>&1 &
  local WATCH_PID=$!

  # --- Cold run assertions (poll until the cold pass has logged each node) ---
  assert_count "$label-cold-A" "A" 1 "$out"
  assert_count "$label-cold-B" "B" 1 "$out"
  assert_count "$label-cold-C" "C" 1 "$out"
  assert_count "$label-cold-D" "D" 1 "$out"

  # --- Step 1: change f1 — A/B/C dirty, D clean. Poll the nodes that recompute
  # first (that advances real time through a full watch pass), then assert D
  # stayed put. ---
  echo "F1-v2" > "$TMP/f1"
  assert_count "$label-step1-A" "A" 2 "$out"
  assert_count "$label-step1-B" "B" 2 "$out"
  assert_count "$label-step1-C" "C" 2 "$out"
  assert_count "$label-step1-D" "D" 1 "$out"

  # --- Step 2: change f3 — D dirty. Poll D first. ---
  echo "F3-v2" > "$TMP/f3"
  assert_count "$label-step2-D" "D" 2 "$out"
  assert_count "$label-step2-B" "B" "$step2_B" "$out"
  assert_count "$label-step2-C" "C" "$step2_C" "$out"
  assert_count "$label-step2-A" "A" 2 "$out"

  # --- Step 3: revert f1 — A/B/C dirty, D clean ---
  echo "F1-v3" > "$TMP/f1"
  assert_count "$label-step3-A" "A" "$step3_A" "$out"
  assert_count "$label-step3-B" "B" "$step3_B" "$out"
  assert_count "$label-step3-C" "C" "$step3_C" "$out"
  assert_count "$label-step3-D" "D" 2 "$out"

  kill $WATCH_PID 2>/dev/null
  wait $WATCH_PID 2>/dev/null || true
}

echo "--- push stabilize ---"
run_test "push-stabilize"


exit $fail
