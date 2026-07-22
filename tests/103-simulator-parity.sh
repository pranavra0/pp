#!/usr/bin/env bash
# Simulator observation preserves process and durable-store behavior at every level, with bounded cold-build overhead.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

store_manifest() {
  local root=$1
  if [ -d "$root/.pp/store" ]; then
    (cd "$root/.pp/store" && find . -type f ! -path './locks/*' -print0 | sort -z | xargs -0 sha256sum)
  fi
}

mkdir -p "$TMP/work"
PROGRAM="$TMP/work/parity.pp"
cat > "$PROGRAM" <<'PP'
let built = force(node { 40 + 2 })
print(built)
PP

PLAIN_HOME="$TMP/plain-home"
mkdir -p "$PLAIN_HOME"
set +e
HOME="$PLAIN_HOME" "$PP" "$PROGRAM" > "$TMP/plain.out" 2> "$TMP/plain.err"
plain_status=$?
set -e
store_manifest "$PLAIN_HOME" > "$TMP/plain.store"

for level in summary semantic evaluation transport; do
  level_home="$TMP/$level-home"
  mkdir -p "$level_home"
  set +e
  HOME="$level_home" "$PP" simulate --event-level "$level" \
    --record "$TMP/$level.jsonl" "$PROGRAM" > "$TMP/$level.out" 2> "$TMP/$level.err"
  level_status=$?
  set -e
  store_manifest "$level_home" > "$TMP/$level.store"
  if [ "$level_status" -eq "$plain_status" ] &&
     cmp -s "$TMP/plain.out" "$TMP/$level.out" &&
     cmp -s "$TMP/plain.err" "$TMP/$level.err" &&
     cmp -s "$TMP/plain.store" "$TMP/$level.store"; then
    ok "parity-$level"
  else
    bad "parity-$level" "status, output, or store artifacts changed"
  fi
done

printf 'unknown-name\n' > "$TMP/work/error.pp"
mkdir -p "$TMP/error-plain-home"
set +e
HOME="$TMP/error-plain-home" "$PP" "$TMP/work/error.pp" \
  > "$TMP/error-plain.out" 2> "$TMP/error-plain.err"
error_status=$?
set -e
for level in summary semantic evaluation transport; do
  mkdir -p "$TMP/error-$level-home"
  set +e
  HOME="$TMP/error-$level-home" "$PP" simulate --event-level "$level" \
    --record "$TMP/error-$level.jsonl" "$TMP/work/error.pp" \
    > "$TMP/error-$level.out" 2> "$TMP/error-$level.err"
  level_status=$?
  set -e
  if [ "$level_status" -eq "$error_status" ] && [ "$level_status" -ne 0 ] &&
     cmp -s "$TMP/error-plain.out" "$TMP/error-$level.out" &&
     cmp -s "$TMP/error-plain.err" "$TMP/error-$level.err"; then
    ok "error-parity-$level"
  else
    bad "error-parity-$level" "failure status or output changed"
  fi
done

BENCH="$TMP/work/overhead.pp"
{
  printf 'print(['
  for i in $(seq 1 64); do
    [ "$i" -eq 1 ] || printf ', '
    printf 'force(node { %d })' "$i"
  done
  printf '])\n'
} > "$BENCH"

measure() {
  local mode=$1 iteration=$2
  local run_home="$TMP/bench-$mode-$iteration"
  local start_ns end_ns
  mkdir -p "$run_home"
  start_ns=$(date +%s%N)
  if [ "$mode" = plain ]; then
    HOME="$run_home" "$PP" "$BENCH" > /dev/null
  else
    HOME="$run_home" "$PP" simulate --event-level transport \
      --record "$TMP/bench-$iteration.jsonl" "$BENCH" > /dev/null
  fi
  end_ns=$(date +%s%N)
  echo $(( (end_ns - start_ns) / 1000000 ))
}

best_plain=999999
best_recorded=999999
for iteration in 1 2 3; do
  plain_ms=$(measure plain "$iteration")
  recorded_ms=$(measure recorded "$iteration")
  [ "$plain_ms" -lt "$best_plain" ] && best_plain=$plain_ms
  [ "$recorded_ms" -lt "$best_recorded" ] && best_recorded=$recorded_ms
done

events=$(wc -l < "$TMP/bench-1.jsonl")
bytes=$(wc -c < "$TMP/bench-1.jsonl")
if [ "$events" -le 800 ] && [ "$bytes" -le $((events * 1024)) ]; then
  ok "bounded-recording" "($events events, $bytes bytes)"
else
  bad "bounded-recording" "$events events, $bytes bytes"
fi
if [ "$best_recorded" -le $((best_plain * 6 + 1000)) ]; then
  ok "bounded-runtime-overhead" "(${best_plain}ms plain, ${best_recorded}ms recorded)"
else
  bad "bounded-runtime-overhead" "${best_plain}ms plain, ${best_recorded}ms recorded"
fi

echo "=== SIMULATOR PARITY TEST PASSED ==="
exit "$fail"
