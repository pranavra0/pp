#!/usr/bin/env bash
# Watch passes reset macro definitions and diagnostic source locations.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ERR="$TMP/iso-err"
PROG="$TMP/iso.pp"

# Put A's expansion past B's source lines so leaked locations are observable.
{
  printf '%s\n' 'defmacro leaker(x) { 111 }'
  printf '\n%.0s' {1..20}
  printf '%s\n' 'print(leaker(0))' 'perform log("session-a-ready")'
} > "$PROG"

timeout -k 5 20 "$PP" --watch --watch-interval 0.1 --grant "fs:$TMP:ro" \
  "$PROG" > /dev/null 2> "$ERR" &
WATCH_PID=$!
trap 'kill "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Watch output arrives after its snapshot; a mid-pass file write is too early.
if wait_for 10 grep -q '^\[info\] session-a-ready$' "$ERR"; then
  ok "session-a-ran"
else
  bad "session-a-ran" "session A never completed" "--- $ERR ---" "$(cat "$ERR")"
fi
ERR_A_END=$(wc -c < "$ERR")

# Publish a complete replacement so the watcher cannot read a truncated file.
cat > "$PROG.next" <<'EOF'
eval-pp("leaker(9)")
car(5)
EOF
mv "$PROG.next" "$PROG"

# Wait for B's diagnostic before stopping the process or inspecting its output.
if wait_for 10 grep -q '^pp: error:' "$ERR"; then
  ok "session-b-ran"
else
  bad "session-b-ran" "session B produced no diagnostic" "--- $ERR ---" "$(cat "$ERR")"
fi

ERR_B="$TMP/iso-err-b"
tail -c +"$((ERR_A_END + 1))" "$ERR" > "$ERR_B"

# Leaking A's macro reaches car(5) instead of the expected unbound-symbol error.
if grep -q 'unbound symbol: leaker' "$ERR_B"; then
  ok "session-b-no-leaked-macro"
else
  bad "session-b-no-leaked-macro" \
    'expected eval-pp("leaker(9)") to be unbound in session B' \
    "--- $ERR_B ---" "$(cat "$ERR_B")"
fi

if grep -q 'iso\.pp:[1-9][0-9]' "$ERR_B"; then
  bad "session-b-no-stale-location" "a session-B diagnostic cites a session-A line" \
    "--- $ERR_B ---" "$(cat "$ERR_B")"
else
  ok "session-b-no-stale-location"
fi
if grep -q 'unbound symbol: leaker at .*iso\.pp:[1-2]$' "$ERR_B"; then
  ok "session-b-own-location"
else
  bad "session-b-own-location" "expected the unbound-symbol error to cite session B's own lines" \
    "--- $ERR_B ---" "$(cat "$ERR_B")"
fi

if [ "$fail" -eq 0 ]; then echo "=== MACRO CONTEXT ISOLATION TEST PASSED ==="; fi
exit "$fail"
