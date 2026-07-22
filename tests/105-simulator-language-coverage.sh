#!/usr/bin/env bash
# Generates the simulator coverage matrix by proving every committed language corpus source preserves its process result.
set -euo pipefail
source tests/lib.sh

matrix="$TMP/simulator-language-coverage.tsv"
printf 'source\tstatus\tevents\n' > "$matrix"
sources=(tests/[0-9]*.pp tests/[0-9]*.ppl examples/*.pp docs/manual/examples/*.pp)
for source in "${sources[@]}"; do
  [ -f "$source" ] || continue
  name=$(printf '%s' "$source" | tr '/.' '__')
  plain_home="$TMP/plain-$name"
  recorded_home="$TMP/recorded-$name"
  mkdir -p "$plain_home" "$recorded_home"
  set +e
  HOME="$plain_home" "$PP" "$source" > "$TMP/plain.out" 2> "$TMP/plain.err"
  plain_status=$?
  HOME="$recorded_home" "$PP" simulate --record "$TMP/events.jsonl" "$source" > "$TMP/recorded.out" 2> "$TMP/recorded.err"
  recorded_status=$?
  set -e
  if [ "$plain_status" -ne "$recorded_status" ] || ! cmp -s "$TMP/plain.out" "$TMP/recorded.out" || ! cmp -s "$TMP/plain.err" "$TMP/recorded.err"; then
    echo "simulator coverage diverged for $source" >&2
    diff -u "$TMP/plain.out" "$TMP/recorded.out" >&2 || true
    diff -u "$TMP/plain.err" "$TMP/recorded.err" >&2 || true
    exit 1
  fi
  events=$(wc -l < "$TMP/events.jsonl")
  [ "$events" -ge 3 ] || { echo "simulator coverage emitted too few events for $source" >&2; exit 1; }
  printf '%s\t%d\t%d\n' "$source" "$recorded_status" "$events" >> "$matrix"
done

rows=$(( $(wc -l < "$matrix") - 1 ))
[ "$rows" -ge 60 ] || { echo "simulator coverage corpus unexpectedly shrank to $rows" >&2; exit 1; }
echo "simulator language coverage: $rows sources"
