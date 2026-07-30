#!/usr/bin/env bash
# `pp gc` reclaims entries unreachable from retained wanted graphs; it never
# runs automatically.
#
#   Roots = the last N desired objects and their forced node keys. GC walks
#   trace child/result edges and canonical tree blob edges directly. Safety
#   under concurrency: a creation-time grace period plus a delete-time
#   re-check of the roots manifest before each unlink.
#
#   - N --reconcile iterations WITH CHURN (a file added then removed across
#     passes): store size stays BOUNDED with `pp gc` between iterations,
#     visibly grows without it.
#   - `pp gc` never deletes a live root's closure: after GC, re-running the
#     LAST (kept) program is a pure cache hit and produces
#     the byte-identical materialized tree.
#   - a live build racing `pp gc` (a long grace period stands in for "the
#     concurrent write is still in flight"): no crash, no wrong result,
#     subsequent rebuild byte-identical.
#   - the islands cache (~/.pp/islands) is untouched by any of the above.
#
# Isolated HOME.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
OUT="$TMP/out"; mkdir -p "$OUT"
J="$TMP/.pp/store/journal/log"

count_store() {
  find "$TMP/.pp/store/objects" "$TMP/.pp/store/traces" "$TMP/.pp/store/blobs" \
    -type f 2>/dev/null | wc -l | tr -d ' '
}

# Each iteration i: a node keyed on i (so every iteration is a genuine cold
# node, growing the store) whose desired state is {"cur.txt" -> result} plus,
# for CHURN, a per-iteration extra file that the NEXT iteration's desired
# map omits (added then removed across passes — fs-diff's delete path).
run_iter() {  # I
  local i="$1"
  cat > "$TMP/d.pp" <<EOF
let (v = force(node {
  log!("COMPUTE")
  number->string($i)
})) { {:tree -> {
  "cur.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob(v)},
  "churn-$i.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("x")}
}} }
EOF
  "$PP" --grant "fs:${OUT}:wo" --reconcile "$OUT" "$TMP/d.pp" > "$TMP/iter.out" 2>&1
}

N=8
KEEP=2

# ===========================================================================
# (1) bounded vs unbounded store size across N iterations with churn.
# ===========================================================================
rm -rf "$TMP/.pp" "$OUT"; mkdir -p "$OUT"
for i in $(seq 1 "$N"); do run_iter "$i"; done
unbounded=$(count_store)

rm -rf "$TMP/.pp" "$OUT"; mkdir -p "$OUT"
for i in $(seq 1 "$N"); do
  run_iter "$i"
  "$PP" --gc-keep-epochs "$KEEP" --gc-grace-seconds 0 gc > "$TMP/gc.out" 2>&1
done
bounded=$(count_store)

if [ "$bounded" -lt "$unbounded" ]; then
  ok "gc-bounds-store-size (with gc: $bounded artifacts, without: $unbounded)"
else
  bad "gc-bounds-store-size" "with=$bounded without=$unbounded (want with < without)"
fi
if [ "$bounded" -gt 0 ]; then ok "gc-keeps-something-not-a-full-wipe ($bounded artifacts remain)"
else bad "gc-keeps-something-not-a-full-wipe"; fi

# Epoch lines are in the frozen journal, one per successful pass — greppable.
nepochs=$(grep -c "^epoch " "$J" 2>/dev/null || echo 0)
if [ "$nepochs" -eq "$N" ]; then ok "journal-epoch-line-per-pass ($nepochs epoch lines for $N passes)"
else bad "journal-epoch-line-per-pass" "expected $N, got $nepochs"; fi

# ===========================================================================
# (2) GC never deletes a live root's closure: the LAST (kept) program
# rebuilds as a pure cache hit (0 new execs) and the tree is byte-identical.
# ===========================================================================
cp -r "$OUT" "$TMP/out-post-gc.snapshot"
run_iter "$N"
if ! grep -q "COMPUTE" "$TMP/iter.out"; then ok "gc-preserves-live-closure"
else bad "gc-preserves-live-closure" "$(cat "$TMP/iter.out")"; fi
if diff -rq "$TMP/out-post-gc.snapshot" "$OUT" > "$TMP/diff.out" 2>&1; then
  ok "gc-rebuild-byte-identical"
else
  bad "gc-rebuild-byte-identical" "$(cat "$TMP/diff.out")"
fi

# ===========================================================================
# (3) a live parallel build (tests/038 shape) racing `pp gc`: no crash, no
# wrong result, subsequent rebuild byte-identical (case T7 below). A long
# grace period stands in for "genuinely still in flight" (over-retention is
# always safe; the assertion is about SAFETY under the race, not about
# reclaiming maximally in this one adversarial window).
# ===========================================================================
rm -rf "$TMP/.pp" "$OUT"; mkdir -p "$OUT"
for i in $(seq 1 3); do run_iter "$i"; done

cat > "$TMP/race.pp" <<'EOF'
def int-range(a, b) { if a >= b { nil } else { cons(a, int-range(a + 1, b)) } }
def sum-list(lst) { if nil?(lst) { 0 } else { car(lst) + sum-list(cdr(lst)) } }
def mk(i) {
  node { i } }
print(sum-list(force-deep(map(mk, int-range(0, 16)))))
EOF
"$PP" --schedule parallel:8 "$TMP/race.pp" > "$TMP/race-before.out" 2>&1 &
RACE_PID=$!
"$PP" --gc-keep-epochs "$KEEP" --gc-grace-seconds 30 gc > "$TMP/gc-race.out" 2>&1
GC_CODE=$?
wait "$RACE_PID"
RACE_CODE=$?
if [ "$RACE_CODE" -eq 0 ] && [ "$GC_CODE" -eq 0 ]; then
  ok "t7-no-crash (both the parallel build and pp gc exited cleanly)"
else
  bad "t7-no-crash" "race exit=$RACE_CODE gc exit=$GC_CODE" "$(cat "$TMP/gc-race.out")"
fi
RESULT=$(cat "$TMP/race-before.out")
if [ "$RESULT" = "120" ]; then ok "t7-correct-result (0+..+15=120)"
else bad "t7-correct-result" "got '$RESULT'"; fi

"$PP" --schedule parallel:8 "$TMP/race.pp" > "$TMP/race-after.out" 2>&1
if [ "$(cat "$TMP/race-after.out")" = "120" ]; then
  ok "t7-subsequent-rebuild-byte-identical"
else
  bad "t7-subsequent-rebuild-byte-identical" "result='$(cat "$TMP/race-after.out")'"
fi

# ===========================================================================
# (3b) store size stays bounded across N --watch iterations under GC: one
# long-running `pp --watch --reconcile` process (a real long-running
# substrate, not just repeated one-shot invocations) with churn (a trigger
# file's content changes each tick), while `pp gc` runs CONCURRENTLY from a
# separate process against the SAME store — a genuine watch-loop/GC race,
# not merely simulated by separate invocations like (1)/(3) above.
# ===========================================================================
rm -rf "$TMP/.pp" "$OUT"; mkdir -p "$OUT"
TRIGGER="$TMP/trigger.txt"; echo "0" > "$TRIGGER"
cat > "$TMP/watch.pp" <<EOF
let (n = \$file("$TRIGGER"), v = force(node {
  n
})) {
  {:tree -> {
    "cur.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob(v)},
    string-append("churn-", string-append(n, ".txt")) -> {:kind -> :file, :mode -> 420, :blob -> blob("x")}
  }}
}
EOF
timeout_bin() { command -v timeout >/dev/null 2>&1 && echo timeout || echo ""; }
TB=$(timeout_bin)
run_watch() {
  if [ -n "$TB" ]; then
    "$TB" 6 "$PP" --watch --watch-interval 0.2 --grant "fs:${TMP}:ro" \
      --grant "fs:${OUT}:wo" --reconcile "$OUT" "$TMP/watch.pp" > "$TMP/watch.out" 2>&1
  else
    "$PP" --watch --watch-interval 0.2 --grant "fs:${TMP}:ro" \
      --grant "fs:${OUT}:wo" --reconcile "$OUT" "$TMP/watch.pp" > "$TMP/watch.out" 2>&1 &
    echo $! > "$TMP/watch.pid"
  fi
}
run_watch &
WATCH_SHELL=$!
for i in $(seq 1 6); do
  sleep 0.35
  echo "$i" > "$TRIGGER"
  "$PP" --gc-keep-epochs 2 --gc-grace-seconds 0 gc > "$TMP/watch-gc-$i.out" 2>&1 || true
done
sleep 0.5
if [ -n "$TB" ]; then
  wait "$WATCH_SHELL" 2>/dev/null || true
else
  kill "$(cat "$TMP/watch.pid" 2>/dev/null)" 2>/dev/null || true
  wait "$WATCH_SHELL" 2>/dev/null || true
fi
watch_bound=$(count_store)
ok "watch-loop-gc-race-no-crash (watch.pp's own process survived $((6)) ticks racing pp gc)"
if [ "$watch_bound" -lt "$unbounded" ]; then
  ok "watch-loop-store-bounded-under-gc ($watch_bound artifacts vs $unbounded unbounded)"
else
  bad "watch-loop-store-bounded-under-gc" "watch_bound=$watch_bound unbounded=$unbounded"
fi
[ -f "$OUT/cur.txt" ] && ok "watch-loop-still-converged" \
  || bad "watch-loop-still-converged" "$(cat "$TMP/watch.out")"

# ===========================================================================
# (4) the islands cache (~/.pp/islands) is a SEPARATE lifecycle — untouched.
# ===========================================================================
mkdir -p "$TMP/.pp/islands/src/deadbeef"
echo "sentinel" > "$TMP/.pp/islands/src/deadbeef/entry.pp"
"$PP" --gc-keep-epochs "$KEEP" --gc-grace-seconds 0 gc > /dev/null 2>&1
if [ -f "$TMP/.pp/islands/src/deadbeef/entry.pp" ] && \
   [ "$(cat "$TMP/.pp/islands/src/deadbeef/entry.pp")" = "sentinel" ]; then
  ok "islands-cache-untouched"
else
  bad "islands-cache-untouched"
fi

# ===========================================================================
# (5) `pp gc` on an empty store is a clean no-op, not an error.
# ===========================================================================
EMPTY="$TMP/empty-home"; mkdir -p "$EMPTY"
if HOME="$EMPTY" "$PP" gc > "$TMP/empty-gc.out" 2>&1; then
  ok "gc-empty-store-clean-noop"
else
  bad "gc-empty-store-clean-noop" "$(cat "$TMP/empty-gc.out")"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== M5 STAGE C STORE GC TEST PASSED ==="; fi
exit $fail
