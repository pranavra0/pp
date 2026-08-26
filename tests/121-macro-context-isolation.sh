#!/usr/bin/env bash
# Macro-context isolation across evaluator instances in one process.
#
# Expansion entry points publish the active invocation's macro context
# (root environment, owner macro table, source location) through a PRIVATE
# pp.rt.lang special. When two evaluator/session instances live in one
# process — here: two watch passes of a single pp process — session B must
# start from a fresh context instead of inheriting whatever session A left
# published:
#
#   * a defmacro from session A is not defined in session B;
#   * every diagnostic session B produces cites B's own source lines — the
#     nested-expansion location published while expanding A's forms never
#     surfaces as B's error range.
#
# Regression for the package split: pp.rt.eval bound NIL around expansion on
# a DIFFERENT, unexported symbol interned in its own package, so pp.rt.lang's
# special kept A's context alive across the session boundary and
# runtime-publish-macro-context's "unless one is already published" guard
# handed A's whole context to B.
#
# Assertions read files the programs write and stderr (unbuffered); watcher
# stdout is block-buffered and lost at SIGTERM, so it pins nothing here.
#
# Runs under an isolated HOME.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OUT="$TMP/iso-out"; ERR="$TMP/iso-err"
PROG="$TMP/iso.pp"
MARKER_A="$TMP/marker-a"; MARKER_B="$TMP/marker-b"
rm -f "$MARKER_A" "$MARKER_B"
printf 'one\n' > "$TMP/phase"

timeout -k 5 20 "$PP" --watch --watch-interval 0.1 --grant "fs:$TMP:rw" \
  "$PROG" > "$OUT" 2> "$ERR" &
WATCH_PID=$!

# =====================================================================
# Session A: defines a macro and pads the source so every A-published
# line number sits far above anything session B contains.
# =====================================================================
cat > "$PROG" <<EOF
defmacro leaker(x) { 111 }
print(leaker(0))
perform write-file("$MARKER_A", "done")
# padding: session A owns lines up to 24; B's file has 4 lines
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
# padding: any later diagnostic citing these lines is leaked state
EOF
for i in $(seq 100); do [ -f "$MARKER_A" ] && break; sleep 0.1; done
if [ -f "$MARKER_A" ]; then ok "session-a-ran"; else
  bad "session-a-ran" "session A never completed" "--- $ERR ---" "$(cat "$ERR")"; fi

# From here on, only session B's diagnostics may reach $ERR. The watcher
# keeps writing at its own offset, so remember where A's diagnostics end
# and split the log afterwards instead of moving the file under it.
ERR_A_END=$(wc -c < "$ERR")

# =====================================================================
# Session B: same process, fresh evaluator/session instance.
# =====================================================================
cat > "$PROG" <<EOF
perform write-file("$MARKER_B", "ran")
eval-pp("leaker(9)")
car(5)
EOF
printf 'two\n' > "$TMP/phase"
for i in $(seq 100); do [ -f "$MARKER_B" ] && break; sleep 0.1; done
if [ -f "$MARKER_B" ]; then ok "session-b-ran"; else
  bad "session-b-ran" "session B never started" "--- $ERR ---" "$(cat "$ERR")"; fi
kill $WATCH_PID 2>/dev/null; wait $WATCH_PID 2>/dev/null || true

# Only session B's diagnostics may appear past A's final byte offset.
ERR_B="$TMP/iso-err-b"
tail -c +"$((ERR_A_END + 1))" "$ERR" > "$ERR_B"

# A's macro is not defined in B: the eval'd call must fail as unbound
# rather than expand to A's answer.
if grep -q 'unbound symbol: leaker' "$ERR_B"; then ok "session-b-no-leaked-macro"
else bad "session-b-no-leaked-macro" \
  "expected eval-pp(\"leaker(9)\") to be unbound in session B" \
  "--- $ERR_B ---" "$(cat "$ERR_B")"; fi

# Every B diagnostic cites B's own 3-line source; a stale context would
# relocate B's nested-expansion failure into A's padded region (>= line 10).
if grep -q 'iso\.pp:[1-9][0-9]' "$ERR_B"; then
  bad "session-b-no-stale-location" "a session-B diagnostic cites a session-A line" \
    "--- $ERR_B ---" "$(cat "$ERR_B")"
else ok "session-b-no-stale-location"; fi
# ...and cites session B's own source (its 3 lines), never a synthetic
# "<?>" origin or a session-A line.
if grep -q 'unbound symbol: leaker at .*iso\.pp:[1-3]$' "$ERR_B"; then
  ok "session-b-own-location"
else bad "session-b-own-location" \
  "expected the unbound-symbol error to cite session B's own lines" \
  "--- $ERR_B ---" "$(cat "$ERR_B")"; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== MACRO CONTEXT ISOLATION TEST PASSED ==="; fi
exit $fail
