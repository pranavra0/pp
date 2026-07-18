#!/usr/bin/env bash
# Fork-at-dispatch scheduler stress test, plus a fenced-effects negative
# check under non-serial schedules.
#
# The worker contract asserted here is deliberate: fork inherits the active
# session state needed by the node body, while the parent receives no OCaml
# value. Results return through the durable object/trace store; reaping and
# killed-worker sandbox cleanup belong to the scheduler handle.
#
#   race:3 — a deliberately slow node, cold, under serial then race:3:
#      identical result, byte-identical program text (only the --schedule
#      flag differs), exactly one surviving trace line, wall-clock roughly a
#      single run (not 3x).
#   N-writer store stress: 64 independent nodes under parallel:16 on one
#      cold store, repeated a bounded number of times: every run produces the
#      correct value (the store round-trips: objects decode, traces parse),
#      a serial re-run against the same warm store is hash-identical, and one
#      cold run's journal has exactly 64 parseable `exec` lines. race:8
#      hammering a SINGLE key with the trace lock disabled (PP_TRACE_LOCK=0 —
#      an internal escape hatch, not a user-facing switch; see store.ml) still
#      yields a parseable trace and a correct subsequent hit.
#   `(fenced ...)` inside a node body still raises under a non-serial
#      schedule (SPEC law 31's negative half, exercised across every policy).
#
# Requires `sh`. Isolated HOME, like tests/010+.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }
JOURNAL="$TMP/.pp/store/journal/log"

# =====================================================================
# race:3 — one deliberately slow node
# =====================================================================
cat > "$TMP/slow.pp" <<'EOF'
def slow() {
  force(node {
    perform run("sh", "-c", "sleep 0.4")
    42 }) }
print(slow())
EOF

rm -rf "$TMP/.pp"
t0=$(now_ms)
"$PP" --grant process "$TMP/slow.pp" > "$TMP/serial.out" 2>&1
t1=$(now_ms)
serial_ms=$((t1 - t0))

rm -rf "$TMP/.pp"
t0=$(now_ms)
"$PP" --grant process --schedule race:3 "$TMP/slow.pp" > "$TMP/race.out" 2>&1
t1=$(now_ms)
race_ms=$((t1 - t0))

if diff -q "$TMP/serial.out" "$TMP/race.out" > /dev/null; then
  ok "race3-identical-result ($(cat "$TMP/race.out"))"
else
  bad "race3-identical-result" "serial: $(cat "$TMP/serial.out")" "race:3:  $(cat "$TMP/race.out")"
fi

ntraces=$(ls "$TMP/.pp/store/traces" 2>/dev/null | wc -l | tr -d ' ')
if [ "$ntraces" -eq 1 ]; then ok "race3-one-trace-file"
else bad "race3-one-trace-file: expected 1, got $ntraces"; fi

tracefile="$TMP/.pp/store/traces/$(ls "$TMP/.pp/store/traces" 2>/dev/null | head -1)"
nlines=$(wc -l < "$tracefile" 2>/dev/null | tr -d ' ')
if [ "$nlines" = "1" ]; then ok "race3-one-surviving-trace-line"
else bad "race3-one-surviving-trace-line: expected 1 line, got $nlines" "$(cat "$tracefile" 2>/dev/null)"; fi

echo "     [timing] serial=${serial_ms}ms race:3=${race_ms}ms"
# Racing 3 forks of a 0.4s node should cost roughly one run, never ~3x
# (serial's own 0.4s-plus-overhead baseline, times 2.5 as a generous margin
# for fork/process-spawn variance on a loaded CI box).
if [ "$race_ms" -lt $((serial_ms * 5 / 2)) ]; then
  ok "race3-wallclock-not-3x (${race_ms}ms < 2.5x serial ${serial_ms}ms)"
else
  bad "race3-wallclock-not-3x: ${race_ms}ms >= 2.5x serial ${serial_ms}ms"
fi

# =====================================================================
# N-writer store stress — 64 independent nodes, parallel:16
# =====================================================================
# Deliberately avoid `(load "stdlib/list.pp")`: its `map` is a plain pp
# fn, and EApply forcing every argument means passing a node
# through `cons`'s argument position there would force each node eagerly —
# the pairing trap. int-range/sum-list below are hand-rolled so nothing in
# this file shadows the builtin (non-forcing) `map`.
cat > "$TMP/stress64.pp" <<'EOF'
def int-range(a, b) { if a >= b { nil } else { cons(a, int-range(a + 1, b)) } }
def sum-list(lst) { if nil?(lst) { 0 } else { car(lst) + sum-list(cdr(lst)) } }
def mk(i) {
  node {
    perform run("sh", "-c", string-append("echo node-", number->string(i)))
    i } }
print(sum-list(force-deep(map(mk, int-range(0, 64)))))
EOF
EXPECTED_SUM=2016  # 0+1+...+63

ITERS=5
iter_fail=0
for i in $(seq 1 "$ITERS"); do
  rm -rf "$TMP/.pp"
  out=$("$PP" --grant process --schedule parallel:16 "$TMP/stress64.pp" 2>"$TMP/stress-err-$i")
  if [ "$out" != "$EXPECTED_SUM" ]; then
    bad "stress64-iter-$i-correct-sum" "got '$out', expected $EXPECTED_SUM" "$(cat "$TMP/stress-err-$i")"
    iter_fail=1
  fi
  ntraces=$(ls "$TMP/.pp/store/traces" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ntraces" -ne 64 ]; then
    bad "stress64-iter-$i-trace-count" "expected 64 distinct trace files, got $ntraces"
    iter_fail=1
  fi
  # Every trace file must parse: each one's lines match the (trace ok|failed ...) shape.
  bad_trace=0
  for tf in "$TMP/.pp/store/traces"/*; do
    grep -qE '^\(trace (ok|failed) ' "$tf" || bad_trace=1
  done
  if [ "$bad_trace" -ne 0 ]; then
    bad "stress64-iter-$i-traces-parse" "found a trace file not matching the expected shape"
    iter_fail=1
  fi
done
if [ "$iter_fail" -eq 0 ]; then
  ok "stress64-$ITERS-cold-iterations (every object/trace round-trips, sum=$EXPECTED_SUM each time)"
fi

# One cold run's journal: exactly 64 parseable exec lines (N concurrent
# journal appends -> N lines, none torn/merged by Journal.append's hardened
# single write_substring on an O_APPEND fd).
rm -rf "$TMP/.pp"
"$PP" --grant process --schedule parallel:16 "$TMP/stress64.pp" > "$TMP/stress-cold.out" 2>"$TMP/stress-cold.err"
nexec=$(grep -c '^exec ' "$JOURNAL" 2>/dev/null || true)
if [ "$nexec" -eq 64 ]; then ok "stress64-journal-64-exec-lines"
else bad "stress64-journal-64-exec-lines: expected 64, got $nexec"; fi
if grep '^exec ' "$JOURNAL" | grep -qvE '^exec sh -c echo node-[0-9]+$'; then
  bad "stress64-journal-lines-well-formed" "$(grep '^exec ' "$JOURNAL" | grep -vE '^exec sh -c echo node-[0-9]+$')"
else
  ok "stress64-journal-lines-well-formed (no torn/merged lines)"
fi

# Serial re-run against the now-warm store: hash-identical (same printed
# value; every node a hit, zero new execs).
e_before=$(grep -c '^exec ' "$JOURNAL" 2>/dev/null || true)
serial_rerun=$("$PP" --grant process --schedule serial "$TMP/stress64.pp" 2>"$TMP/stress-serial-rerun.err")
e_after=$(grep -c '^exec ' "$JOURNAL" 2>/dev/null || true)
if [ "$serial_rerun" = "$EXPECTED_SUM" ] && [ "$e_after" -eq "$e_before" ]; then
  ok "stress64-serial-rerun-hash-identical (0 new execs)"
else
  bad "stress64-serial-rerun-hash-identical" "got '$serial_rerun' (want $EXPECTED_SUM), $((e_after - e_before)) new execs" "$(cat "$TMP/stress-serial-rerun.err")"
fi

# ---- race:8 hammering a SINGLE key, trace lock disabled ----
# PP_TRACE_LOCK=0 is an internal escape hatch (store.ml's with_trace_lock),
# not a documented user switch: it disables the per-key lockf around
# store_trace's read-modify-write so this test can demonstrate LAW 37's
# drop-soundness (store.ml's store_trace comment) holds even without the
# lock, not just with it.
cat > "$TMP/onekey.pp" <<'EOF'
def one() {
  force(node {
    perform run("sh", "-c", "echo racing")
    99 }) }
print(one())
EOF
rm -rf "$TMP/.pp"
out=$(PP_TRACE_LOCK=0 "$PP" --grant process --schedule race:8 "$TMP/onekey.pp" 2>"$TMP/onekey.err")
if [ "$out" = "99" ]; then ok "race8-samekey-nolock-correct-result"
else bad "race8-samekey-nolock-correct-result" "got '$out'" "$(cat "$TMP/onekey.err")"; fi
tf=$(ls "$TMP/.pp/store/traces" 2>/dev/null | head -1)
if [ -n "$tf" ] && grep -qE '^\(trace (ok|failed) ' "$TMP/.pp/store/traces/$tf"; then
  ok "race8-samekey-nolock-trace-parses"
else
  bad "race8-samekey-nolock-trace-parses" "trace file missing or malformed"
fi
# A subsequent (unlocked, still-warm) run hits and adds no new execs.
e_before=$(grep -c '^exec ' "$JOURNAL" 2>/dev/null || true)
out2=$(PP_TRACE_LOCK=0 "$PP" --grant process --schedule race:8 "$TMP/onekey.pp" 2>"$TMP/onekey2.err")
e_after=$(grep -c '^exec ' "$JOURNAL" 2>/dev/null || true)
if [ "$out2" = "99" ] && [ "$e_after" -eq "$e_before" ]; then
  ok "race8-samekey-nolock-subsequent-hit"
else
  bad "race8-samekey-nolock-subsequent-hit" "got '$out2', $((e_after - e_before)) new execs"
fi

# ---- fork inherits the dynamic session state needed by node bodies ----
cat > "$TMP/inherited-session.pp" <<'EOF'
def int-range(a, b) { if a >= b { nil } else { cons(a, int-range(a + 1, b)) } }
def sum-list(xs) { if nil?(xs) { 0 } else { car(xs) + sum-list(cdr(xs)) } }
def make(i) { node { perform ask(i) + $config("offset") } }
with {
  config: { :offset -> 10 },
  handlers: { :ask -> fn(n) { n + 1 } }
} {
  print(sum-list(force-deep(map(make, int-range(1, 3)))))
}
EOF
out=$($PP --schedule parallel:2 "$TMP/inherited-session.pp" 2>"$TMP/inherited-session.err")
if [ "$out" = "25" ]; then
  ok "parallel-inherits-config-and-handler-state"
else
  bad "parallel-inherits-config-and-handler-state" "got '$out'" "$(cat "$TMP/inherited-session.err")"
fi

# =====================================================================
# Fenced effects (SPEC law 31) stay disallowed inside a node body under
# every non-serial schedule too — placement must never widen what a node
# may do.
# =====================================================================
cat > "$TMP/fenced-in-node.pp" <<'EOF'
let bad = node {
  fenced("x", {}); 1 }
force(bad)
EOF
for spec in "parallel:4" "race:3"; do
  rm -rf "$TMP/.pp"
  "$PP" --schedule "$spec" "$TMP/fenced-in-node.pp" > "$TMP/fenced-$spec.out" 2>&1
  if grep -q "fenced effects may not appear inside node bodies" "$TMP/fenced-$spec.out"; then
    ok "fenced-in-node-still-raises-under-$spec"
  else
    bad "fenced-in-node-still-raises-under-$spec" "$(cat "$TMP/fenced-$spec.out")"
  fi
done

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== PHASE-3 PARALLEL STRESS TEST PASSED ==="; fi
exit $fail
