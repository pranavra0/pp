#!/usr/bin/env bash
# Pins evaluation, scheduler, process, capability, domain, reconcile, and watch instrumentation at their owning boundaries.
set -euo pipefail
source tests/lib.sh

has() { grep -q "\"category\":\"$1\"" "$2" || { echo "missing $1 events in $2" >&2; exit 1; }; }

printf 'print(1 + 2)\n' > "$TMP/evaluation.pp"
"$PP" simulate --event-level evaluation --record "$TMP/evaluation.jsonl" "$TMP/evaluation.pp" >/dev/null
has evaluation "$TMP/evaluation.jsonl"

cat > "$TMP/scheduler.pp" <<'PP'
def make(n) { node { n } }
force-deep(map(make, [1, 2]))
PP
"$PP" simulate --schedule parallel:2 --record "$TMP/scheduler.jsonl" "$TMP/scheduler.pp" >/dev/null
has scheduler "$TMP/scheduler.jsonl"

printf 'print(hash-map-get(perform run("true"), "exit"))\n' > "$TMP/process.pp"
"$PP" simulate --grant process --record "$TMP/process.jsonl" "$TMP/process.pp" >/dev/null
has process "$TMP/process.jsonl"
has capability "$TMP/process.jsonl"

mkdir -p "$TMP/root"
printf '{"a.txt" -> "hello"}\n' > "$TMP/reconcile.pp"
"$PP" simulate --reconcile "$TMP/root" --grant "fs:$TMP/root:rw" --record "$TMP/reconcile.jsonl" "$TMP/reconcile.pp" >/dev/null 2>&1
has domain "$TMP/reconcile.jsonl"
has reconcile "$TMP/reconcile.jsonl"

printf 'print($file("%s"))\n' "$TMP/input" > "$TMP/watch.pp"
printf 'one\n' > "$TMP/input"
"$PP" simulate --watch --watch-interval 0.05 --grant "fs:$TMP:ro" --record "$TMP/watch.jsonl" "$TMP/watch.pp" >/dev/null 2>&1 &
watch_pid=$!
trap 'kill "$watch_pid" 2>/dev/null || true' EXIT
wait_for 5 grep -q '"kind":"watch.poll"' "$TMP/watch.jsonl"
printf 'two\n' > "$TMP/input"
wait_for 5 grep -q '"kind":"watch.changed"' "$TMP/watch.jsonl"
kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
trap - EXIT
has watch "$TMP/watch.jsonl"

echo "simulator runtime event families passed"
