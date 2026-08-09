#!/usr/bin/env bash
# Fenced effects: (fenced KIND SPEC-MAP) registers a non-convergent action
# in the scripting tier (SPEC law 31).
#
#   The reconciler/supervisor sequences it after convergent work, journaling
#   intent/done around each action.  Fenced effects may not appear inside
#   node bodies.  A crash between intent and done leaves an unknown-status
#   entry that is resolved by --fenced-policy (retry | abort | ask), never
#   by silent retry.
#
# Runs under an isolated HOME; single engine.
# pins: LAW-31
set -uo pipefail
. "$(dirname "$0")/lib.sh"
OUT="$TMP/out"

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/outlog}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$file"; fail=1; fi
}

mkdir -p "$OUT"

# --- (a) fenced inside a node body is an error ---
cat > "$TMP/in-node.pp" <<'EOF'
let bad = node {
  fenced("x", {}); 1 }
force(bad)
EOF
"$PP" "$TMP/in-node.pp" > "$TMP/outlog" 2>&1 || true
assert "node-body-error" "fenced effects may not appear inside node bodies" present
"$PP" "$TMP/in-node.pp" > "$TMP/outlog" 2>&1 || true
assert "node-body-error" "fenced effects may not appear inside node bodies" present

# --- (b) fenced in scripting tier without reconciler is a no-op ---
cat > "$TMP/noop.pp" <<'EOF'
do {
  fenced("x", {"run" -> ["/usr/bin/false"]})
  print(42)
}
EOF
"$PP" "$TMP/noop.pp" > "$TMP/outlog" 2>&1
assert "scripting-noop" "^42$" present

# --- (c) kind tokens cannot corrupt the space-delimited recovery record ---
cat > "$TMP/bad-kind.pp" <<'EOF'
do {
  fenced("touch file", {"run" -> ["/usr/bin/false"]})
  {:tree -> {}}
}
EOF
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" \
  "$TMP/bad-kind.pp" > "$TMP/outlog" 2>&1 || true
assert "kind-whitespace-rejected" "kind must be a nonempty token" present

# --- (c) a simple fenced action executes once and journals intent/done ---
rm -rf "$TMP/.pp" "$OUT"
rm -f "$TMP/touched"
cat > "$TMP/simple.pp" <<EOF
do {
  fenced("touch-file", {"run" -> ["/usr/bin/touch", "$TMP/touched"]})
  {:tree -> {"file.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("hello")}}}
}
EOF
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/simple.pp" > "$TMP/outlog" 2>&1
assert "simple-summary" "create=1" present
[ -f "$TMP/touched" ] && echo "ok   simple-ran" \
  || { echo "FAIL simple-ran: action did not run"; fail=1; }
JOURNAL="$TMP/.pp/store/journal/log"
if [ -f "$JOURNAL" ] && \
   grep -q "intent fenced" "$JOURNAL" && \
   grep -q "done fenced" "$JOURNAL"; then
  echo "ok   simple-journal"
else
  echo "FAIL simple-journal: missing intent/done fenced entries"; fail=1
fi

# --- (e) simulated crash recovery: retry re-runs the unknown action once ---
rm -rf "$TMP/.pp" "$OUT"
rm -f "$TMP/touched" "$TMP/retry-runs"
cat > "$TMP/retry-action.sh" <<'EOF'
#!/bin/sh
printf 'run\n' >> "$1"
EOF
chmod +x "$TMP/retry-action.sh"
cat > "$TMP/retry.pp" <<EOF
do {
  fenced("retry-once", {"run" -> ["$TMP/retry-action.sh", "$TMP/retry-runs"]})
  {:tree -> {"file.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("hello")}}}
}
EOF
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/retry.pp" > "$TMP/outlog" 2>&1
initial_count=$(wc -l < "$TMP/retry-runs" | tr -d ' ')
if [ "$initial_count" -eq 1 ]; then
  echo "ok   recovery-retry-initial-execution"
else
  echo "FAIL recovery-retry-initial-execution: expected 1 run, got $initial_count"; fail=1
fi
# Simulate a crash between intent and done by removing the done fenced line.
rm -f "$TMP/retry-runs"
perl -ni -e 'print unless /^done fenced/' "$JOURNAL"
# Keep the recovery journal otherwise valid: one pending intent is retried.
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/retry.pp" > "$TMP/outlog" 2>&1
 retry_count=$(wc -l < "$TMP/retry-runs" | tr -d ' ')
 if [ "$retry_count" -eq 1 ]; then
   echo "ok   retry-recovery-ran"
 else
   echo "FAIL retry-recovery-ran: expected 1 run, got $retry_count"; fail=1
 fi
 done_count=$(grep -Ec '^done fenced [0-9a-f]{64} [0-9a-f]{64}$' "$JOURNAL" || true)
 if [ "$done_count" -eq 1 ]; then
   echo "ok   retry-recovery-done"
 else
   echo "FAIL retry-recovery-done: expected 1, got $done_count"; fail=1
 fi
 
 # Every malformed journal shape is a hard stop, before the action can run.
bad_journal_case() {
  local name="$1" record="$2" status
  rm -rf "$TMP/.pp" "$OUT"
  rm -f "$TMP/retry-runs"
  "$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/retry.pp" > "$TMP/outlog" 2>&1 || true
  rm -f "$TMP/retry-runs"
  perl -ni -e 'print unless /^done fenced/' "$JOURNAL"
  printf '%s\n' "$record" >> "$JOURNAL"
  "$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/retry.pp" > "$TMP/outlog" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -Eqi 'malformed|unterminated|invalid journal' "$TMP/outlog" &&
     [ ! -s "$TMP/retry-runs" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: status=$status"; cat "$TMP/outlog"; fail=1
  fi
}
 bad_journal_case "journal-extra-fields" \
   'done fenced 0000000000000000000000000000000000000000000000000000000000000000 0000000000000000000000000000000000000000000000000000000000000000 extra'
 bad_journal_case "journal-truncated-record" \
   'intent fenced 0000000000000000000000000000000000000000000000000000000000000000'
 bad_journal_case "journal-bad-digest" \
   'done fenced 0000000000000000000000000000000000000000000000000000000000000000 1111111111111111111111111111111111111111111111111111111111111111'
 bad_journal_case "journal-corrupt-key" \
  'intent fenced corrupt-key 0000000000000000000000000000000000000000000000000000000000000000 retry 0000000000000000000000000000000000000000000000000000000000000000'
rm -rf "$TMP/.pp" "$OUT"
rm -f "$TMP/retry-runs"
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/retry.pp" > "$TMP/outlog" 2>&1 || true
rm -f "$TMP/retry-runs"
perl -ni -e 'print unless /^done fenced/' "$JOURNAL"
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/retry.pp" > "$TMP/outlog" 2>&1
retry_count=$(wc -l < "$TMP/retry-runs" | tr -d ' ')
if [ "$retry_count" -eq 1 ]; then
  echo "ok   recovery-retry-ran"
else
  echo "FAIL recovery-retry-ran: expected exactly 1 recovery execution, got $retry_count"; fail=1
fi
done_count=$(grep -Ec '^done fenced [0-9a-f]{64} [0-9a-f]{64}$' "$JOURNAL" || true)
if [ "$done_count" -eq 1 ]; then
  echo "ok   recovery-retry-journal (done_count=$done_count)"
else
  echo "FAIL recovery-retry-journal: expected 1 done fenced, got $done_count"; fail=1
fi
# --- (f) a corrupted action key is never executed during recovery ---
rm -rf "$TMP/.pp" "$OUT"
cat > "$TMP/count-action.sh" <<'EOF'
#!/bin/sh
printf 'run\n' >> "$1"
EOF
chmod +x "$TMP/count-action.sh"
cat > "$TMP/corrupt-key.pp" <<EOF
do {
  fenced("count", {"run" -> ["$TMP/count-action.sh", "$TMP/count-runs"]})
  {:tree -> {}}
}
EOF
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" \
  "$TMP/corrupt-key.pp" > "$TMP/outlog" 2>&1
perl -ni -e 's/^(intent fenced) \S+/$1 corrupt-key/; print unless /^done fenced/' \
  "$JOURNAL"
rm -f "$TMP/count-runs"
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" \
  "$TMP/corrupt-key.pp" > "$TMP/outlog" 2>&1
run_count=0
[ -f "$TMP/count-runs" ] && run_count=$(wc -l < "$TMP/count-runs" | tr -d ' ')
if [ "$run_count" -eq 0 ]; then echo "ok   corrupt-key-no-recovery-execution"
else echo "FAIL corrupt-key-no-recovery-execution: expected 0 recovery runs, got $run_count"; fail=1; fi


# --- (f) simulated crash recovery: abort marks the unknown action done ---
rm -rf "$TMP/.pp" "$OUT"
rm -f "$TMP/touched"
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/simple.pp" > "$TMP/outlog" 2>&1
perl -ni -e 'print unless /^done fenced/' "$JOURNAL"
rm -f "$TMP/touched"
"$PP" --fenced-policy abort --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/simple.pp" > "$TMP/outlog" 2>&1
assert "recovery-abort-policy" "applying policy=abort" present
if [ ! -f "$TMP/touched" ]; then
  echo "ok   recovery-abort-action-skipped"
else
  echo "FAIL recovery-abort-action-skipped: action marker was created"; fail=1
fi
# Recovery appended an abort done; the fresh pass skipped.
done_count=$(grep -Ec '^done fenced [0-9a-f]{64} [0-9a-f]{64}$' "$JOURNAL" || true)
if [ "$done_count" -eq 1 ]; then echo "ok   recovery-abort-done-count"
else echo "FAIL recovery-abort-done-count: expected 1, got $done_count"; fail=1; fi

# --- (g) real crash recovery under --watch: kill pp between intent and done ---
rm -rf "$TMP/.pp" "$OUT"
rm -f "$TMP/fenced-active" "$TMP/fenced-continue" "$TMP/fenced-pid"
cleanup_action() {
  if [ -f "$TMP/fenced-pid" ]; then
    kill -9 "$(cat "$TMP/fenced-pid")" 2>/dev/null || true
    rm -f "$TMP/fenced-pid"
  fi
}
trap cleanup_action EXIT
cat > "$TMP/fenced-action.sh" <<'EOF'
#!/bin/sh
echo active > "$1"
echo $$ > "$3"
if [ -f "$2" ]; then
  exit 0
fi
exec sleep 60
EOF
chmod +x "$TMP/fenced-action.sh"
cat > "$TMP/watch-crash.pp" <<EOF
do {
  fenced("block-until-continue", {"run" -> ["$TMP/fenced-action.sh", "$TMP/fenced-active", "$TMP/fenced-continue", "$TMP/fenced-pid"]})
  {:tree -> {"file.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("hello")}}}
}
EOF
"$PP" --watch --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" --watch-interval 1 "$TMP/watch-crash.pp" > "$TMP/watch-out" 2>&1 &
WATCH_PID=$!
# Wait for the fenced intent, the action-start marker, and the action PID.
for i in $(seq 1 50); do
  [ -f "$JOURNAL" ] && grep -q "intent fenced" "$JOURNAL" && break
  sleep 0.1
done
for i in $(seq 1 50); do
  [ -f "$TMP/fenced-active" ] && [ -f "$TMP/fenced-pid" ] && break
  sleep 0.1
done
# Kill pp first (while the action is still sleeping) so no done can be written.
kill -9 "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
# Then kill the orphaned action process.
cleanup_action
if [ -f "$TMP/fenced-active" ]; then echo "ok   watch-crash-started"
else echo "FAIL watch-crash-started"; fail=1; fi
if grep -q "^done fenced" "$JOURNAL"; then
  echo "FAIL watch-crash-premature-done"; fail=1
else echo "ok   watch-crash-no-done"
fi
# Now resume with the continue file present so the retried action completes.
rm -f "$TMP/fenced-active"
touch "$TMP/fenced-continue"
"$PP" --fenced-policy retry --reconcile "$OUT" --grant "fs:$OUT:rw" "$TMP/watch-crash.pp" > "$TMP/outlog" 2>&1
[ -f "$TMP/fenced-active" ] && echo "ok   watch-crash-recovery-ran" \
  || { echo "FAIL watch-crash-recovery-ran"; fail=1; }
done_count=$(grep -Ec '^done fenced [0-9a-f]{64} [0-9a-f]{64}$' "$JOURNAL" || true)
if [ "$done_count" -eq 1 ]; then echo "ok   watch-crash-done-count"
else echo "FAIL watch-crash-done-count: expected 1, got $done_count"; fail=1; fi
trap - EXIT

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== FENCED EFFECTS TEST PASSED ==="; fi
exit $fail
