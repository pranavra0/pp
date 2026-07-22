#!/usr/bin/env bash
# Semantic JSONL recording explains cold rebuilds and warm verified hits without changing program output.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

assert() {
  local name=$1 pattern=$2 presence=$3 file=$4
  if grep -qE "$pattern" "$file"; then
    [ "$presence" = present ] && ok "$name" || bad "$name" "unexpected: $pattern"
  else
    [ "$presence" = absent ] && ok "$name" || bad "$name" "missing: $pattern"
  fi
}

mkdir -p "$HOME/work"
PROGRAM="$HOME/work/build.pp"
cat > "$PROGRAM" <<'PP'
let built = force(node { 40 + 2 })
print(built)
PP

"$PP" "$PROGRAM" > "$TMP/plain.out" 2> "$TMP/plain.err"
rm -rf "$HOME/.pp"
"$PP" simulate --record "$TMP/cold.jsonl" "$PROGRAM" > "$TMP/cold.out" 2> "$TMP/cold.err"
"$PP" simulate --record "$TMP/warm.jsonl" "$PROGRAM" > "$TMP/warm.out" 2> "$TMP/warm.err"

cmp "$TMP/plain.out" "$TMP/cold.out"
cmp "$TMP/plain.err" "$TMP/cold.err"
cmp "$TMP/plain.out" "$TMP/warm.out"
cmp "$TMP/plain.err" "$TMP/warm.err"

assert "cold-run-created" '"kind":"run.created"' present "$TMP/cold.jsonl"
assert "cold-cache-miss" '"kind":"cache.miss".*"reason":"no_stored_trace"' present "$TMP/cold.jsonl"
assert "cold-rebuild-started" '"kind":"node.rebuild","phase":"started"' present "$TMP/cold.jsonl"
assert "cold-rebuild-finished" '"kind":"node.rebuild","phase":"finished"' present "$TMP/cold.jsonl"
assert "cold-run-finished" '"kind":"run.finished"' present "$TMP/cold.jsonl"
assert "warm-cache-hit" '"kind":"cache.hit"' present "$TMP/warm.jsonl"
assert "warm-no-rebuild" '"kind":"node.rebuild"' absent "$TMP/warm.jsonl"
assert "recording-no-source-path" "$PROGRAM" absent "$TMP/cold.jsonl"

printf 'unknown-name\n' > "$TMP/bad.pp"
if "$PP" simulate --record "$TMP/failed.jsonl" "$TMP/bad.pp" > /dev/null 2>&1; then
  bad "failed-run-exit" "invalid program unexpectedly succeeded"
else
  ok "failed-run-exit"
fi
assert "failed-run-event" '"kind":"run.failed"' present "$TMP/failed.jsonl"
assert "failed-run-not-finished" '"kind":"run.finished"' absent "$TMP/failed.jsonl"
assert "failed-run-redacts-message" 'unknown-name' absent "$TMP/failed.jsonl"

event_ids=$(sed -n 's/.*"event_id":\([0-9][0-9]*\).*/\1/p' "$TMP/cold.jsonl")
expected_ids=$(seq 1 "$(wc -l < "$TMP/cold.jsonl")")
[ "$event_ids" = "$expected_ids" ] || {
  echo "FAIL event ids are not contiguous" >&2
  exit 1
}

echo "=== SIMULATOR EVENT TEST PASSED ==="
exit "$fail"
